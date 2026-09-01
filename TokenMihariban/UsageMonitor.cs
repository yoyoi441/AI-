using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using TokenMihariban.Logic;
using TokenMihariban.Models;
using TokenMihariban.Notifications;
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
    private NotifyIcon? _trayIcon;
    private readonly FirestoreSyncService _syncService;
    private IReadOnlyList<UsageEvent> _remoteClaudeEvents = Array.Empty<UsageEvent>();
    private IReadOnlyList<CodexUsageEvent> _remoteCodexEvents = Array.Empty<CodexUsageEvent>();

    public bool IsDeviceSyncAvailable => _syncService.IsAvailable;
    public string? SyncPairingCode => _syncService.PairingCode;

    public UsageMonitor()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _projectsDirectory = Path.Combine(home, ".claude", "projects");
        _codexSessionsDirectory = Path.Combine(home, ".codex", "sessions");

        Directory.CreateDirectory(_projectsDirectory);
        Directory.CreateDirectory(_codexSessionsDirectory);

        _syncService = new FirestoreSyncService();
        _syncService.RemoteDataChanged += OnRemoteDataChanged;

        Refresh();
        RestartFallbackTimer();
        StartFileWatchers();
    }

    public void AttachTrayIcon(NotifyIcon trayIcon) => _trayIcon = trayIcon;

    private void StartFileWatchers()
    {
        _claudeWatcher = CreateWatcher(_projectsDirectory);
        _codexWatcher = CreateWatcher(_codexSessionsDirectory);
    }

    private FileSystemWatcher CreateWatcher(string directory)
    {
        var watcher = new FileSystemWatcher(directory)
        {
            IncludeSubdirectories = true,
            Filter = "*.jsonl",
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
        lock (_refreshLock)
        {
            RefreshClaude();
            RefreshCodex();
            CheckUsageAlerts();
            localClaude = _allEvents.ToArray();
            localCodex = _allCodexEvents.ToArray();
        }
        SnapshotUpdated?.Invoke(this, EventArgs.Empty);
        _syncService.UpdateLocalEvents(localClaude, localCodex);
    }

    public string CreateSyncPairingCode() => _syncService.CreatePairingCode();

    public bool SetSyncPairingCode(string? code) => _syncService.SetPairingCode(code);

    public Task<bool> SyncNowAsync() => _syncService.SyncLatestAsync();

    private void OnRemoteDataChanged(object? sender, RemoteUsageData data)
    {
        lock (_refreshLock)
        {
            _remoteClaudeEvents = data.ClaudeEvents;
            _remoteCodexEvents = data.CodexEvents;
            ComputeClaudeSnapshot();
            ComputeCodexSnapshot();
        }
        SnapshotUpdated?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Raw per-event rows for the Settings export tab, covering this PC's full history —
    /// not just today/7-day rollups. <c>_allEvents</c>/<c>_allCodexEvents</c> never drop
    /// old entries once parsed, so any past date range is available without re-reading
    /// log files.
    /// </summary>
    public List<UsageExportRow> ExportRows(DateTime start, DateTime end)
    {
        return UsageExporter.Rows(
            _allEvents,
            _allCodexEvents,
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
        _syncService.RemoteDataChanged -= OnRemoteDataChanged;
        _syncService.Dispose();
    }
}
