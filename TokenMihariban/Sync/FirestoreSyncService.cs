using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using TokenMihariban.Models;

namespace TokenMihariban.Sync;

public sealed record RemoteUsageData(
    IReadOnlyList<UsageEvent> ClaudeEvents,
    IReadOnlyList<CodexUsageEvent> CodexEvents);

/// <summary>
/// Optional cross-device sync using the same Firestore document layout as the macOS
/// app. Pairing is deliberately opt-in: no network traffic occurs until a valid
/// eight-character pairing code has been created or entered in Settings.
/// </summary>
public sealed class FirestoreSyncService : IDisposable
{
    private const int UploadBatchSize = 400;
    private static readonly TimeSpan RecentWindow = TimeSpan.FromDays(9);
    private static readonly Regex PairingCodePattern = new("^[A-HJ-NP-Z2-9]{8}$", RegexOptions.Compiled);
    private readonly AppSettings _settings = AppSettings.Shared;
    private readonly HttpClient _client;
    private readonly FirebaseConfig? _config;
    private readonly SemaphoreSlim _syncGate = new(1, 1);
    private readonly System.Threading.Timer _pollTimer;
    private UsageEvent[] _latestClaude = Array.Empty<UsageEvent>();
    private CodexUsageEvent[] _latestCodex = Array.Empty<CodexUsageEvent>();
    private bool _disposed;

    public event EventHandler<RemoteUsageData>? RemoteDataChanged;

    public bool IsAvailable => _config is not null;
    public string? PairingCode => NormalizePairingCode(_settings.GetString("syncGroupId"));

    public string DeviceId
    {
        get
        {
            var existing = _settings.GetString("syncDeviceId");
            if (!string.IsNullOrWhiteSpace(existing)) return existing;
            var generated = Guid.NewGuid().ToString();
            _settings.SetString("syncDeviceId", generated);
            return generated;
        }
    }

    public FirestoreSyncService()
    {
        _config = FirebaseConfig.Load();
        _client = new HttpClient { Timeout = TimeSpan.FromSeconds(45) };
        _client.DefaultRequestHeaders.UserAgent.ParseAdd("TokenMihariban-Windows/0.2");
        _pollTimer = new System.Threading.Timer(_ => _ = SyncLatestAsync(), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(60));
    }

    public string CreatePairingCode()
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        Span<byte> bytes = stackalloc byte[8];
        RandomNumberGenerator.Fill(bytes);
        var chars = new char[8];
        for (var i = 0; i < chars.Length; i++) chars[i] = alphabet[bytes[i] % alphabet.Length];
        var code = new string(chars);
        SetPairingCode(code);
        return code;
    }

    public bool SetPairingCode(string? code)
    {
        var normalized = NormalizePairingCode(code);
        if (normalized is null)
        {
            if (!string.IsNullOrWhiteSpace(code)) return false;
            _settings.Remove("syncGroupId");
            RemoteDataChanged?.Invoke(this, new RemoteUsageData(Array.Empty<UsageEvent>(), Array.Empty<CodexUsageEvent>()));
            return true;
        }
        _settings.SetString("syncGroupId", normalized);
        _settings.Remove("lastUploadedClaudeEventAt_" + normalized);
        _settings.Remove("lastUploadedCodexEventAt_" + normalized);
        _ = SyncLatestAsync();
        return true;
    }

    public void UpdateLocalEvents(IEnumerable<UsageEvent> claudeEvents, IEnumerable<CodexUsageEvent> codexEvents)
    {
        _latestClaude = claudeEvents.ToArray();
        _latestCodex = codexEvents.ToArray();
        _ = SyncLatestAsync();
    }

    public async Task<bool> SyncLatestAsync()
    {
        if (_disposed || _config is null || PairingCode is not { } code) return false;
        if (!await _syncGate.WaitAsync(0).ConfigureAwait(false)) return false;
        try
        {
            await UploadClaudeAsync(code, _latestClaude).ConfigureAwait(false);
            await UploadCodexAsync(code, _latestCodex).ConfigureAwait(false);
            var cutoff = DateTime.UtcNow.Subtract(RecentWindow);
            var remoteClaudeTask = QueryClaudeAsync(code, cutoff);
            var remoteCodexTask = QueryCodexAsync(code, cutoff);
            await Task.WhenAll(remoteClaudeTask, remoteCodexTask).ConfigureAwait(false);
            RemoteDataChanged?.Invoke(this, new RemoteUsageData(remoteClaudeTask.Result, remoteCodexTask.Result));
            return true;
        }
        catch
        {
            // Sync is supplementary. Local monitoring must keep working when offline,
            // Firebase is unavailable, or a deployment has restrictive rules.
            return false;
        }
        finally
        {
            _syncGate.Release();
        }
    }

    private async Task UploadClaudeAsync(string code, IReadOnlyList<UsageEvent> events)
    {
        var cutoff = UploadCutoff("lastUploadedClaudeEventAt_" + code);
        var selected = events.Where(e => e.Timestamp.ToUniversalTime() >= cutoff).OrderBy(e => e.Timestamp).ToArray();
        if (selected.Length == 0) return;
        var writes = selected.Select(e => WriteDocument(code, "claudeEvents", DocumentId(DeviceId, e.SessionId, e.Timestamp), ClaudeFields(e))).ToArray();
        await CommitInBatchesAsync(writes).ConfigureAwait(false);
        SaveWatermark("lastUploadedClaudeEventAt_" + code, selected.Max(e => e.Timestamp));
    }

    private async Task UploadCodexAsync(string code, IReadOnlyList<CodexUsageEvent> events)
    {
        var cutoff = UploadCutoff("lastUploadedCodexEventAt_" + code);
        var selected = events.Where(e => e.Timestamp.ToUniversalTime() >= cutoff).OrderBy(e => e.Timestamp).ToArray();
        if (selected.Length == 0) return;
        var writes = selected.Select(e => WriteDocument(code, "codexEvents", DocumentId(DeviceId, e.SessionId, e.Timestamp), CodexFields(e))).ToArray();
        await CommitInBatchesAsync(writes).ConfigureAwait(false);
        SaveWatermark("lastUploadedCodexEventAt_" + code, selected.Max(e => e.Timestamp));
    }

    private DateTime UploadCutoff(string key)
    {
        var floor = DateTime.UtcNow.Subtract(RecentWindow);
        return DateTime.TryParse(_settings.GetString(key), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var saved)
            ? (saved.ToUniversalTime() < floor ? floor : saved.ToUniversalTime())
            : floor;
    }

    private void SaveWatermark(string key, DateTime timestamp) =>
        _settings.SetString(key, timestamp.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));

    private async Task CommitInBatchesAsync(IReadOnlyList<object> writes)
    {
        for (var offset = 0; offset < writes.Count; offset += UploadBatchSize)
        {
            var batch = writes.Skip(offset).Take(UploadBatchSize).ToArray();
            using var content = JsonContent(new { writes = batch });
            using var response = await _client.PostAsync(Endpoint(":commit"), content).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
        }
    }

    private async Task<IReadOnlyList<UsageEvent>> QueryClaudeAsync(string code, DateTime cutoff)
    {
        using var response = await RunQueryAsync(code, "claudeEvents", cutoff).ConfigureAwait(false);
        var result = new List<UsageEvent>();
        foreach (var fields in DocumentFields(response))
        {
            if (StringValue(fields, "deviceId") == DeviceId || !MapValue(fields, "event", out var e)) continue;
            if (TryDate(e, "timestamp", out var timestamp))
            {
                result.Add(new UsageEvent(timestamp, StringValue(e, "model"), IntValue(e, "inputTokens"), IntValue(e, "outputTokens"), IntValue(e, "cacheCreationTokens"), IntValue(e, "cacheReadTokens"), StringValue(e, "sessionId"), StringValue(e, "projectPath", "unknown")));
            }
        }
        return result;
    }

    private async Task<IReadOnlyList<CodexUsageEvent>> QueryCodexAsync(string code, DateTime cutoff)
    {
        using var response = await RunQueryAsync(code, "codexEvents", cutoff).ConfigureAwait(false);
        var result = new List<CodexUsageEvent>();
        foreach (var fields in DocumentFields(response))
        {
            if (StringValue(fields, "deviceId") == DeviceId || !MapValue(fields, "event", out var e)) continue;
            if (TryDate(e, "timestamp", out var timestamp))
            {
                result.Add(new CodexUsageEvent(timestamp, StringValue(e, "model"), IntValue(e, "inputTokens"), IntValue(e, "cachedInputTokens"), IntValue(e, "outputTokens"), IntValue(e, "reasoningOutputTokens"), StringValue(e, "sessionId"), StringValue(e, "projectPath", "unknown")));
            }
        }
        return result;
    }

    private async Task<JsonDocument> RunQueryAsync(string code, string collection, DateTime cutoff)
    {
        var query = new
        {
            structuredQuery = new
            {
                from = new[] { new { collectionId = collection } },
                where = new
                {
                    fieldFilter = new
                    {
                        field = new { fieldPath = "event.timestamp" },
                        op = "GREATER_THAN_OR_EQUAL",
                        value = TimestampValue(cutoff)
                    }
                }
            }
        };
        using var content = JsonContent(query);
        using var response = await _client.PostAsync(GroupEndpoint(code, ":runQuery"), content).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        return JsonDocument.Parse(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
    }

    private IEnumerable<JsonElement> DocumentFields(JsonDocument document)
    {
        foreach (var row in document.RootElement.EnumerateArray())
        {
            if (row.TryGetProperty("document", out var doc) && doc.TryGetProperty("fields", out var fields)) yield return fields;
        }
    }

    private object WriteDocument(string code, string collection, string documentId, object fields) => new
    {
        update = new
        {
            name = $"projects/{_config!.ProjectId}/databases/(default)/documents/syncGroups/{code}/{collection}/{documentId}",
            fields
        }
    };

    private object ClaudeFields(UsageEvent e) => new
    {
        deviceId = StringValue(DeviceId),
        @event = MapValue(new
        {
            timestamp = TimestampValue(e.Timestamp), model = StringValue(e.Model), inputTokens = IntValue(e.InputTokens),
            outputTokens = IntValue(e.OutputTokens), cacheCreationTokens = IntValue(e.CacheCreationTokens),
            cacheReadTokens = IntValue(e.CacheReadTokens), sessionId = StringValue(e.SessionId), projectPath = StringValue(e.ProjectPath)
        })
    };

    private object CodexFields(CodexUsageEvent e) => new
    {
        deviceId = StringValue(DeviceId),
        @event = MapValue(new
        {
            timestamp = TimestampValue(e.Timestamp), model = StringValue(e.Model), inputTokens = IntValue(e.InputTokens),
            cachedInputTokens = IntValue(e.CachedInputTokens), outputTokens = IntValue(e.OutputTokens),
            reasoningOutputTokens = IntValue(e.ReasoningOutputTokens), sessionId = StringValue(e.SessionId), projectPath = StringValue(e.ProjectPath)
        })
    };

    private string Endpoint(string suffix) => $"https://firestore.googleapis.com/v1/projects/{Uri.EscapeDataString(_config!.ProjectId)}/databases/(default)/documents{suffix}?key={Uri.EscapeDataString(_config.ApiKey)}";
    private string GroupEndpoint(string code, string suffix) => $"https://firestore.googleapis.com/v1/projects/{Uri.EscapeDataString(_config!.ProjectId)}/databases/(default)/documents/syncGroups/{Uri.EscapeDataString(code)}{suffix}?key={Uri.EscapeDataString(_config.ApiKey)}";
    private static StringContent JsonContent(object value) => new(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json");
    private static object StringValue(string value) => new { stringValue = value };
    private static object IntValue(long value) => new { integerValue = value.ToString(CultureInfo.InvariantCulture) };
    private static object TimestampValue(DateTime value) => new { timestampValue = value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture) };
    private static object MapValue(object fields) => new { mapValue = new { fields } };

    private static string StringValue(JsonElement fields, string name, string fallback = "") =>
        fields.TryGetProperty(name, out var value) && value.TryGetProperty("stringValue", out var text) ? text.GetString() ?? fallback : fallback;

    private static long IntValue(JsonElement fields, string name)
    {
        if (!fields.TryGetProperty(name, out var value) || !value.TryGetProperty("integerValue", out var number)) return 0;
        return number.ValueKind == JsonValueKind.String
            ? long.TryParse(number.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedString) ? parsedString : 0
            : number.TryGetInt64(out var parsedNumber) ? parsedNumber : 0;
    }

    private static bool TryDate(JsonElement fields, string name, out DateTime timestamp)
    {
        timestamp = default;
        return fields.TryGetProperty(name, out var value) && value.TryGetProperty("timestampValue", out var text) &&
               DateTime.TryParse(text.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out timestamp);
    }

    private static bool MapValue(JsonElement fields, string name, out JsonElement mapFields)
    {
        mapFields = default;
        return fields.TryGetProperty(name, out var value) && value.TryGetProperty("mapValue", out var map) && map.TryGetProperty("fields", out mapFields);
    }

    private static string DocumentId(string deviceId, string sessionId, DateTime timestamp)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(deviceId + "|" + sessionId + "|" + timestamp.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    public static string? NormalizePairingCode(string? code)
    {
        var normalized = code?.Trim().ToUpperInvariant();
        return normalized is not null && PairingCodePattern.IsMatch(normalized) ? normalized : null;
    }

    public void Dispose()
    {
        _disposed = true;
        _pollTimer.Dispose();
        _client.Dispose();
        _syncGate.Dispose();
    }

    private sealed record FirebaseConfig(string ProjectId, string ApiKey)
    {
        public static FirebaseConfig? Load()
        {
            try
            {
                var path = Path.Combine(AppContext.BaseDirectory, "firebase.config.json");
                if (!File.Exists(path)) return null;
                using var doc = JsonDocument.Parse(File.ReadAllText(path));
                var root = doc.RootElement;
                var projectId = root.GetProperty("projectId").GetString();
                var apiKey = root.GetProperty("apiKey").GetString();
                return string.IsNullOrWhiteSpace(projectId) || string.IsNullOrWhiteSpace(apiKey) ? null : new FirebaseConfig(projectId, apiKey);
            }
            catch { return null; }
        }
    }
}
