using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Data.Sqlite;
using TokenMihariban.Logic;
using TokenMihariban.Models;
using TokenMihariban.Notifications;
using TokenMihariban.Ollama;
using TokenMihariban.Parsing;
using TokenMihariban.Sync;

namespace TokenMihariban;

/// <summary>
/// Watches both Claude Code's (<c>~/.claude/projects</c>) and Codex CLI's
/// (<c>~/.codex/sessions</c>) local logs for new usage events, recomputes both
/// snapshots, and raises <see cref="SnapshotUpdated"/> for the tray icon/popup to pick
/// up. Ported from the Mac app's <c>UsageMonitor</c> — same two-pipeline-never-merged
/// design (Claude's numbers are heuristic estimates, Codex's are official), same
/// event-driven-refresh-plus-fallback-timer approach, same in-memory-only file offsets
/// (a fresh launch always re-parses full history once). All data stays on this PC.
/// </summary>
public sealed class UsageMonitor : IDisposable
{
    public UsageSnapshot Snapshot { get; private set; } = UsageSnapshot.Empty;
    public CodexSnapshot CodexSnapshot { get; private set; } = Models.CodexSnapshot.Empty;
    public OllamaSnapshot OllamaSnapshot { get; private set; } = Models.OllamaSnapshot.Empty;
    public AIToolSnapshot AIToolSnapshot { get; private set; } = Models.AIToolSnapshot.Empty;
    public long RemoteOllamaTodayTokens { get; private set; }
    public OllamaProxyState OllamaProxyState => _ollamaProxy.State;
    public string? OllamaProxyError => _ollamaProxy.ErrorMessage;
    public string OllamaLocalProxyUrl => $"http://127.0.0.1:{OllamaProxyService.LocalPort}";
    public string OllamaCloudProxyUrl => $"http://127.0.0.1:{OllamaProxyService.CloudPort}";
    public event EventHandler? SnapshotUpdated;

    private double _refreshIntervalSeconds = 60;
    public double RefreshIntervalSeconds
    {
        get => _refreshIntervalSeconds;
        set
        {
            _refreshIntervalSeconds = value;
            RestartFallbackTimer();
        }
    }

    private System.Threading.Timer? _fallbackTimer;
    private FileSystemWatcher? _claudeWatcher;
    private FileSystemWatcher? _codexWatcher;
    private FileSystemWatcher? _geminiWatcher;
    private FileSystemWatcher? _openCodeWatcher;
    private System.Threading.Timer? _debounceTimer;
    private readonly object _debounceLock = new();
    private readonly object _refreshLock = new();

    private readonly List<UsageEvent> _allEvents = new();
    private readonly Dictionary<string, long> _fileOffsets = new();

    private readonly List<CodexUsageEvent> _allCodexEvents = new();
    private readonly Dictionary<string, long> _codexFileOffsets = new();
    private CodexRateLimitWindow? _latestCodexPrimaryWindow;
    private CodexRateLimitWindow? _latestCodexSecondaryWindow;
    private DateTime? _latestCodexWindowEventTimestamp;

    private readonly string _projectsDirectory;
    private readonly string _codexSessionsDirectory;
    private readonly string _geminiDirectory;
    private readonly string _openCodeDirectory;
    private NotifyIcon? _trayIcon;
    private readonly FirestoreSyncService _syncService;
    private IReadOnlyList<UsageEvent> _remoteClaudeEvents = Array.Empty<UsageEvent>();
    private IReadOnlyList<CodexUsageEvent> _remoteCodexEvents = Array.Empty<CodexUsageEvent>();
    private IReadOnlyList<OllamaUsageEvent> _remoteOllamaEvents = Array.Empty<OllamaUsageEvent>();
    private readonly OllamaUsageStore _ollamaStore = new();
    private readonly OllamaProxyService _ollamaProxy = new();
    private readonly List<OllamaUsageEvent> _allOllamaEvents = new();
    private readonly List<AIToolUsageEvent> _allAIToolEvents = new();
    private IReadOnlyList<AIToolUsageEvent> _remoteAIToolEvents = Array.Empty<AIToolUsageEvent>();
    private DateTime? _lastOpenCodeDatabaseWriteTimeUtc;

    public bool IsDeviceSyncAvailable => _syncService.IsAvailable;
    public string? SyncPairingCode => _syncService.PairingCode;

    public UsageMonitor()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _projectsDirectory = Path.Combine(home, ".claude", "projects");
        _codexSessionsDirectory = Path.Combine(home, ".codex", "sessions");
        _geminiDirectory = Path.Combine(home, ".gemini", "tmp");
        _openCodeDirectory = Path.Combine(home, ".local", "share", "opencode");

        Directory.CreateDirectory(_projectsDirectory);
        Directory.CreateDirectory(_codexSessionsDirectory);
        Directory.CreateDirectory(_geminiDirectory);
        Directory.CreateDirectory(_openCodeDirectory);

        _syncService = new FirestoreSyncService();
        _syncService.RemoteDataChanged += OnRemoteDataChanged;
        _allOllamaEvents.AddRange(_ollamaStore.Load());
        _ollamaProxy.UsageCaptured += OnOllamaUsageCaptured;
        _ollamaProxy.StateChanged += OnOllamaProxyStateChanged;

        Refresh();
        RestartFallbackTimer();
        StartFileWatchers();
        var ollamaEnabled = !AppSettings.Shared.HasKey("ollamaMonitoringEnabled") || AppSettings.Shared.GetBool("ollamaMonitoringEnabled", true);
        if (ollamaEnabled) _ollamaProxy.Start();
    }

    public void AttachTrayIcon(NotifyIcon trayIcon) => _trayIcon = trayIcon;

    public void SetOllamaMonitoringEnabled(bool enabled)
    {
        AppSettings.Shared.SetBool("ollamaMonitoringEnabled", enabled);
        if (enabled) _ollamaProxy.Start();
        else _ollamaProxy.Stop();
        SnapshotUpdated?.Invoke(this, EventArgs.Empty);
    }

    private void OnOllamaUsageCaptured(object? sender, OllamaUsageEvent usage)
    {
        lock (_refreshLock)
        {
            if (_allOllamaEvents.Any(x => x.RequestId == usage.RequestId)) return;
            _allOllamaEvents.Add(usage);
            _ollamaStore.Append(usage);
            ComputeOllamaSnapshot();
            CheckUsageAlerts();
        }
        SnapshotUpdated?.Invoke(this, EventArgs.Empty);
    }

    private void OnOllamaProxyStateChanged(object? sender, EventArgs e) => SnapshotUpdated?.Invoke(this, EventArgs.Empty);

    private void StartFileWatchers()
    {
        _claudeWatcher = CreateWatcher(_projectsDirectory);
        _codexWatcher = CreateWatcher(_codexSessionsDirectory);
        _geminiWatcher = CreateWatcher(_geminiDirectory, "session-*.*");
        _openCodeWatcher = CreateWatcher(_openCodeDirectory, "*.db*");
    }

    private FileSystemWatcher CreateWatcher(string directory, string filter = "*.jsonl")
    {
        var watcher = new FileSystemWatcher(directory)
        {
            IncludeSubdirectories = true,
            Filter = filter,
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName
        };
        watcher.Changed += (_, _) => ScheduleDebouncedRefresh();
        watcher.Created += (_, _) => ScheduleDebouncedRefresh();
        watcher.Renamed += (_, _) => ScheduleDebouncedRefresh();
        watcher.EnableRaisingEvents = true;
        return watcher;
    }

    /// <summary>
    /// FileSystemWatcher can fire several events in quick succession for one logical
    /// write; coalescing into a single refresh ~500ms after the last event avoids
    /// re-parsing the same growing file many times per second.
    /// </summary>
    private void ScheduleDebouncedRefresh()
    {
        lock (_debounceLock)
        {
            _debounceTimer?.Dispose();
            _debounceTimer = new System.Threading.Timer(_ => Refresh(), null, 500, Timeout.Infinite);
        }
    }

    private void RestartFallbackTimer()
    {
        _fallbackTimer?.Dispose();
        var interval = TimeSpan.FromSeconds(Math.Max(5, _refreshIntervalSeconds));
        _fallbackTimer = new System.Threading.Timer(_ => Refresh(), null, interval, interval);
    }

    public void Refresh()
    {
        UsageEvent[] localClaude;
        CodexUsageEvent[] localCodex;
        OllamaUsageEvent[] localOllama;
        AIToolUsageEvent[] localAITools;
        lock (_refreshLock)
        {
            RefreshClaude();
            RefreshCodex();
            ComputeOllamaSnapshot();
            RefreshAITools();
            CheckUsageAlerts();
            localClaude = _allEvents.ToArray();
            localCodex = _allCodexEvents.ToArray();
            localOllama = _allOllamaEvents.ToArray();
            localAITools = _allAIToolEvents.ToArray();
        }
        SnapshotUpdated?.Invoke(this, EventArgs.Empty);
        _syncService.UpdateLocalEvents(localClaude, localCodex, localOllama, localAITools);
    }

    public Task<string?> CreateSyncPairingCodeAsync() => _syncService.CreatePairingCodeAsync();

    public Task<bool> JoinSyncPairingCodeAsync(string? code) => _syncService.JoinPairingCodeAsync(code);

    public Task UnpairSyncAsync() => _syncService.UnpairAsync();

    public Task<bool> SyncNowAsync() => _syncService.SyncLatestAsync();

    private void OnRemoteDataChanged(object? sender, RemoteUsageData data)
    {
        lock (_refreshLock)
        {
            _remoteClaudeEvents = data.ClaudeEvents;
            _remoteCodexEvents = data.CodexEvents;
            _remoteOllamaEvents = data.OllamaEvents;
            _remoteAIToolEvents = data.AIToolEvents;
            ComputeClaudeSnapshot();
            ComputeCodexSnapshot();
            ComputeOllamaSnapshot();
            ComputeAIToolSnapshot();
        }
        SnapshotUpdated?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Raw per-event rows for the Settings export tab, combining this PC and paired
    /// devices just like the on-screen totals.
    /// </summary>
    public List<UsageExportRow> ExportRows(DateTime start, DateTime end)
    {
        return UsageExporter.Rows(
            _allEvents.Concat(_remoteClaudeEvents).ToArray(),
            _allCodexEvents.Concat(_remoteCodexEvents).ToArray(),
            _allOllamaEvents.Concat(_remoteOllamaEvents).ToArray(),
            _allAIToolEvents.Concat(_remoteAIToolEvents).ToArray(),
            start,
            end
        );
    }

    private void CheckUsageAlerts()
    {
        var settings = AppSettings.Shared;
        var notificationsEnabled = settings.HasKey("notificationsEnabled") ? settings.GetBool("notificationsEnabled", true) : true;
        if (!notificationsEnabled || _trayIcon is null) return;

        var window = new DailyTimeWindow(
            settings.HasKey("customWindowStartMinute") ? settings.GetInt("customWindowStartMinute", DailyTimeWindow.Default.StartMinute) : DailyTimeWindow.Default.StartMinute,
            settings.HasKey("customWindowEndMinute") ? settings.GetInt("customWindowEndMinute", DailyTimeWindow.Default.EndMinute) : DailyTimeWindow.Default.EndMinute
        );
        var lang = AppLanguageExtensions.FromStorageValue(settings.GetString("appLanguage"));
        var dateKey = TodayDateKey();

        if (settings.GetBool("dailyTargetEnabled", false))
        {
            CheckTarget(Snapshot.TodayTotalTokens, settings.GetDouble("claudeDailyTokenTarget"), "Claude Code", "daily", dateKey, lang);
            CheckTarget(CodexSnapshot.TodayTotalTokens, settings.GetDouble("codexDailyTokenTarget"), "Codex", "daily", dateKey, lang);
            CheckTarget(OllamaSnapshot.TodayTotalTokens, settings.GetDouble("ollamaDailyTokenTarget"), "Ollama", "daily", dateKey, lang);
            CheckTarget(AIToolSnapshot.TodayTotalTokens, settings.GetDouble("aiToolsDailyTokenTarget"), L.String("aiToolsTitle", lang), "daily", dateKey, lang);
        }
        if (settings.GetBool("windowTargetEnabled", false))
        {
            CheckTarget(Snapshot.HourlyTokensToday.TokensInWindow(window), settings.GetDouble("claudeWindowTokenTarget"), "Claude Code", "window", dateKey, lang);
            CheckTarget(CodexSnapshot.HourlyTokensToday.TokensInWindow(window), settings.GetDouble("codexWindowTokenTarget"), "Codex", "window", dateKey, lang);
        }

        var block = Snapshot.CurrentBlock;
        var target = Snapshot.ReferenceTokens;
        if (block is not null && target is not null)
        {
            CheckBlockPaceAlert(block, target.Value, lang);
        }
    }

    private void CheckTarget(long current, double target, string providerName, string kind, string dateKey, AppLanguage lang)
    {
        if (target <= 0 || current <= target || _trayIcon is null) return;
        UsageNotifier.NotifyOnce(
            _trayIcon,
            dedupeKey: $"windows_{kind}_{providerName}_{dateKey}",
            title: L.String("notificationExceededTitleFormat", lang, providerName),
            body: L.String("notificationExceededBodyFormat", lang, providerName, FormatNumber(current), FormatNumber((long)target))
        );
    }

    /// <summary>
    /// One-time-per-block heads-up: at the current block's observed pace, its token
    /// target will be reached soon — unlike <see cref="CheckTarget"/>, which only fires
    /// after a target is already exceeded, this gives the user time to react beforehand.
    /// </summary>
    private void CheckBlockPaceAlert(SessionBlockSummary block, long target, AppLanguage lang)
    {
        var minutesUntil = PaceAlertEvaluator.MinutesUntilTargetReached(block, target);
        if (minutesUntil is null || minutesUntil > PaceAlertEvaluator.WarnWithinMinutes || _trayIcon is null) return;
        UsageNotifier.NotifyOnce(
            _trayIcon,
            dedupeKey: $"windows_pace_claude_{new DateTimeOffset(block.Start).ToUnixTimeSeconds()}",
            title: L.String("notificationPaceWarningTitleFormat", lang, "Claude Code"),
            body: L.String("notificationPaceWarningBodyFormat", lang, (int)Math.Round(minutesUntil.Value), FormatNumber(target))
        );
    }

    private static string TodayDateKey()
    {
        var now = DateTime.Now;
        return $"{now.Year}-{now.Month}-{now.Day}";
    }

    private static string FormatNumber(long count) => count.ToString("N0", System.Globalization.CultureInfo.InvariantCulture);

    private void RefreshClaude()
    {
        var newEvents = new List<UsageEvent>();
        foreach (var path in FindLogFiles(_projectsDirectory))
        {
            var offset = _fileOffsets.GetValueOrDefault(path, 0);
            List<UsageEvent> events;
            long newOffset;
            try
            {
                (events, newOffset) = JsonlParser.ParseFile(path, offset);
            }
            catch
            {
                continue;
            }
            _fileOffsets[path] = newOffset;
            newEvents.AddRange(events);
        }

        if (newEvents.Count > 0) _allEvents.AddRange(newEvents);

        ComputeClaudeSnapshot();
    }

    private void ComputeClaudeSnapshot()
    {
        var settings = AppSettings.Shared;
        var manualTarget = settings.GetDouble("manualBlockTokenTarget");
        var colorHex = settings.GetString("gaugeColorHex") ?? GaugeAppearance.Default.ColorHex;
        var useGradient = settings.HasKey("gaugeUseGradient") ? settings.GetBool("gaugeUseGradient", true) : GaugeAppearance.Default.UseGradient;
        var style = GaugeDisplayStyleExtensions.FromStorageValue(settings.GetString("gaugeStyle"));
        Snapshot = SnapshotComputer.ComputeSnapshot(_allEvents.Concat(_remoteClaudeEvents).ToArray(), manualTarget, new GaugeAppearance { ColorHex = colorHex, UseGradient = useGradient, Style = style });
    }

    private void RefreshCodex()
    {
        var newEvents = new List<CodexUsageEvent>();
        foreach (var path in FindLogFiles(_codexSessionsDirectory))
        {
            var fileName = Path.GetFileNameWithoutExtension(path);
            if (!Path.GetFileName(path).StartsWith("rollout-", StringComparison.Ordinal)) continue;

            var offset = _codexFileOffsets.GetValueOrDefault(path, 0);
            CodexJsonlParser.ParseResult result;
            try
            {
                result = CodexJsonlParser.ParseFile(path, fileName, offset);
            }
            catch
            {
                continue;
            }
            _codexFileOffsets[path] = result.NewOffset;
            newEvents.AddRange(result.Events);

            if (result.LatestWindowEventTimestamp is { } eventTimestamp &&
                (_latestCodexWindowEventTimestamp is null || eventTimestamp > _latestCodexWindowEventTimestamp))
            {
                _latestCodexWindowEventTimestamp = eventTimestamp;
                if (result.LatestPrimaryWindow is not null) _latestCodexPrimaryWindow = result.LatestPrimaryWindow;
                if (result.LatestSecondaryWindow is not null) _latestCodexSecondaryWindow = result.LatestSecondaryWindow;
            }
        }

        if (newEvents.Count > 0) _allCodexEvents.AddRange(newEvents);

        ComputeCodexSnapshot();
    }

    private void ComputeCodexSnapshot()
    {
        var colorHex = AppSettings.Shared.GetString("codexColorHex") ?? Models.CodexSnapshot.Empty.ColorHex;
        CodexSnapshot = SnapshotComputer.ComputeCodexSnapshot(_allCodexEvents.Concat(_remoteCodexEvents).ToArray(), _latestCodexPrimaryWindow, _latestCodexSecondaryWindow, colorHex);
    }

    private void ComputeOllamaSnapshot()
    {
        var settings = AppSettings.Shared;
        var dailyTarget = settings.GetBool("dailyTargetEnabled", false) ? settings.GetDouble("ollamaDailyTokenTarget") : 0;
        var colorHex = settings.GetString("ollamaColorHex") ?? Models.OllamaSnapshot.Empty.ColorHex;
        OllamaSnapshot = OllamaUsageComputer.Compute(
            _allOllamaEvents.Concat(_remoteOllamaEvents).ToArray(),
            dailyTarget,
            colorHex);
        RemoteOllamaTodayTokens = OllamaUsageComputer.Compute(
            _remoteOllamaEvents.ToArray(),
            0,
            colorHex).TodayTotalTokens;
    }

    private void RefreshAITools()
    {
        var cutoff = DateTime.UtcNow.AddDays(-9);
        var local = new List<AIToolUsageEvent>();
        var previousGemini = _allAIToolEvents.Where(x => x.Tool == AIToolKind.GeminiCli).ToArray();
        try
        {
            foreach (var path in Directory.EnumerateFiles(_geminiDirectory, "session-*.*", SearchOption.AllDirectories))
            {
                var extension = Path.GetExtension(path);
                if (extension is not ".json" and not ".jsonl" || File.GetLastWriteTimeUtc(path) < cutoff) continue;
                try { local.AddRange(GeminiSessionParser.Parse(File.ReadAllBytes(path), Path.GetFileNameWithoutExtension(path))); }
                catch { }
            }
        }
        catch { }
        if (local.Count == 0 && previousGemini.Length > 0) local.AddRange(previousGemini);
        local.AddRange(ReadOpenCodeEvents(cutoff));
        _allAIToolEvents.Clear();
        _allAIToolEvents.AddRange(local.GroupBy(x => x.EventId).Select(x => x.Last()));
        ComputeAIToolSnapshot();
    }

    private IReadOnlyList<AIToolUsageEvent> ReadOpenCodeEvents(DateTime cutoff)
    {
        var previous = _allAIToolEvents.Where(x => x.Tool == AIToolKind.OpenCode).ToArray();
        var database = new[] { "opencode.db", "opencode-prod.db" }.Select(x => Path.Combine(_openCodeDirectory, x)).FirstOrDefault(File.Exists);
        if (database is null) return previous;
        var writeTime = File.GetLastWriteTimeUtc(database);
        if (_lastOpenCodeDatabaseWriteTimeUtc == writeTime)
            return previous;
        var result = new List<AIToolUsageEvent>();
        try
        {
            var builder = new SqliteConnectionStringBuilder { DataSource = database, Mode = SqliteOpenMode.ReadOnly, Cache = SqliteCacheMode.Shared, DefaultTimeout = 2 };
            using var connection = new SqliteConnection(builder.ToString());
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT data FROM message WHERE time_created >= $cutoff";
            command.Parameters.AddWithValue("$cutoff", new DateTimeOffset(cutoff).ToUnixTimeMilliseconds());
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (!reader.IsDBNull(0) && OpenCodeMessageParser.ParseMessageData(reader.GetString(0)) is { } usage) result.Add(usage);
            }
            _lastOpenCodeDatabaseWriteTimeUtc = writeTime;
        }
        catch { return previous; }
        return result.Count > 0 || previous.Length == 0 ? result : previous;
    }

    private void ComputeAIToolSnapshot()
    {
        var settings = AppSettings.Shared;
        var target = settings.GetBool("dailyTargetEnabled", false) ? settings.GetDouble("aiToolsDailyTokenTarget") : 0;
        var color = settings.GetString("aiToolsColorHex") ?? Models.AIToolSnapshot.Empty.ColorHex;
        AIToolSnapshot = AIToolUsageComputer.Compute(_allAIToolEvents.Concat(_remoteAIToolEvents).ToArray(), target, color);
    }

    private static List<string> FindLogFiles(string directory)
    {
        if (!Directory.Exists(directory)) return new List<string>();
        try
        {
            return Directory.EnumerateFiles(directory, "*.jsonl", SearchOption.AllDirectories).ToList();
        }
        catch
        {
            return new List<string>();
        }
    }

    public void Dispose()
    {
        _fallbackTimer?.Dispose();
        _debounceTimer?.Dispose();
        _claudeWatcher?.Dispose();
        _codexWatcher?.Dispose();
        _geminiWatcher?.Dispose();
        _openCodeWatcher?.Dispose();
        _ollamaProxy.UsageCaptured -= OnOllamaUsageCaptured;
        _ollamaProxy.StateChanged -= OnOllamaProxyStateChanged;
        _ollamaProxy.Dispose();
        _syncService.RemoteDataChanged -= OnRemoteDataChanged;
        _syncService.Dispose();
    }
}
