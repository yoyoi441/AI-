using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
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
    IReadOnlyList<CodexUsageEvent> CodexEvents,
    IReadOnlyList<OllamaUsageEvent> OllamaEvents);

/// <summary>
/// Opt-in cross-device sync backed by Firebase Authentication and Firestore.
/// A random 80-bit group ID acts as the pairing capability, while Firestore rules only
/// permit authenticated group members to read or write usage data.
/// </summary>
public sealed class FirestoreSyncService : IDisposable
{
    private const int UploadBatchSize = 400;
    private const string RefreshTokenSetting = "firebaseRefreshTokenProtected";
    private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    private static readonly TimeSpan RecentWindow = TimeSpan.FromDays(9);
    private static readonly Regex PairingCodePattern = new("^[A-HJ-NP-Z2-9]{16}$", RegexOptions.Compiled);
    private readonly AppSettings _settings = AppSettings.Shared;
    private readonly HttpClient _client;
    private readonly FirebaseConfig? _config;
    private readonly SemaphoreSlim _syncGate = new(1, 1);
    private readonly SemaphoreSlim _authGate = new(1, 1);
    private readonly System.Threading.Timer _pollTimer;
    private UsageEvent[] _latestClaude = Array.Empty<UsageEvent>();
    private CodexUsageEvent[] _latestCodex = Array.Empty<CodexUsageEvent>();
    private OllamaUsageEvent[] _latestOllama = Array.Empty<OllamaUsageEvent>();
    private string? _idToken;
    private string? _userId;
    private DateTimeOffset _idTokenExpiresAt;
    private bool _disposed;

    public event EventHandler<RemoteUsageData>? RemoteDataChanged;

    public bool IsAvailable => _config is not null;
    private string? GroupId => NormalizePairingCode(_settings.GetString("syncGroupId"));
    public string? PairingCode => GroupId is { } id ? FormatPairingCode(id) : null;

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
        _client.DefaultRequestHeaders.UserAgent.ParseAdd("TokenMihariban-Windows/0.3");
        _pollTimer = new System.Threading.Timer(_ => _ = SyncLatestAsync(), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(60));
    }

    public async Task<string?> CreatePairingCodeAsync()
    {
        if (_config is null) return null;
        var code = GeneratePairingCode();
        try
        {
            var auth = await GetAuthAsync().ConfigureAwait(false);
            await CreateGroupAndMembershipAsync(code, auth).ConfigureAwait(false);
            SavePairingCode(code);
            _ = SyncLatestAsync();
            return FormatPairingCode(code);
        }
        catch
        {
            return null;
        }
    }

    public async Task<bool> JoinPairingCodeAsync(string? code)
    {
        if (_config is null || NormalizePairingCode(code) is not { } normalized) return false;
        try
        {
            var auth = await GetAuthAsync().ConfigureAwait(false);
            await JoinGroupAsync(normalized, auth).ConfigureAwait(false);
            SavePairingCode(normalized);
            _ = SyncLatestAsync();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public async Task UnpairAsync()
    {
        var code = GroupId;
        _settings.Remove("syncGroupId");
        RemoteDataChanged?.Invoke(this, new RemoteUsageData(Array.Empty<UsageEvent>(), Array.Empty<CodexUsageEvent>(), Array.Empty<OllamaUsageEvent>()));
        if (_config is null || code is null) return;
        try
        {
            var auth = await GetAuthAsync().ConfigureAwait(false);
            using var request = AuthenticatedRequest(HttpMethod.Delete, DocumentEndpoint($"syncGroups/{code}/members/{auth.UserId}"), auth.IdToken);
            using var response = await _client.SendAsync(request).ConfigureAwait(false);
            if (response.StatusCode is not HttpStatusCode.NotFound) response.EnsureSuccessStatusCode();
        }
        catch
        {
            // Local unpairing is complete even if the remote membership cannot be removed offline.
        }
    }

    private void SavePairingCode(string code)
    {
        _settings.SetString("syncGroupId", code);
        _settings.Remove("lastUploadedClaudeEventAt_" + code);
        _settings.Remove("lastUploadedCodexEventAt_" + code);
        _settings.Remove("lastUploadedOllamaEventAt_" + code);
    }

    public void UpdateLocalEvents(IEnumerable<UsageEvent> claudeEvents, IEnumerable<CodexUsageEvent> codexEvents, IEnumerable<OllamaUsageEvent> ollamaEvents)
    {
        _latestClaude = claudeEvents.ToArray();
        _latestCodex = codexEvents.ToArray();
        _latestOllama = ollamaEvents.ToArray();
        _ = SyncLatestAsync();
    }

    public async Task<bool> SyncLatestAsync()
    {
        if (_disposed || _config is null || GroupId is not { } code) return false;
        if (!await _syncGate.WaitAsync(0).ConfigureAwait(false)) return false;
        try
        {
            var auth = await GetAuthAsync().ConfigureAwait(false);
            await UploadClaudeAsync(code, _latestClaude, auth.IdToken).ConfigureAwait(false);
            await UploadCodexAsync(code, _latestCodex, auth.IdToken).ConfigureAwait(false);
            await UploadOllamaAsync(code, _latestOllama, auth.IdToken).ConfigureAwait(false);
            var cutoff = DateTime.UtcNow.Subtract(RecentWindow);
            var remoteClaudeTask = QueryClaudeAsync(code, cutoff, auth.IdToken);
            var remoteCodexTask = QueryCodexAsync(code, cutoff, auth.IdToken);
            var remoteOllamaTask = QueryOllamaAsync(code, cutoff, auth.IdToken);
            await Task.WhenAll(remoteClaudeTask, remoteCodexTask, remoteOllamaTask).ConfigureAwait(false);
            RemoteDataChanged?.Invoke(this, new RemoteUsageData(remoteClaudeTask.Result, remoteCodexTask.Result, remoteOllamaTask.Result));
            return true;
        }
        catch
        {
            // Local monitoring continues to work while offline or if access is revoked.
            return false;
        }
        finally
        {
            _syncGate.Release();
        }
    }

    private async Task CreateGroupAndMembershipAsync(string code, AuthSession auth)
    {
        var writes = new object[]
        {
            WriteDocumentByPath($"syncGroups/{code}", new
            {
                ownerUid = StringValue(auth.UserId),
                createdAt = TimestampValue(DateTime.UtcNow),
                schemaVersion = IntValue(2)
            }),
            WriteDocumentByPath($"syncGroups/{code}/members/{auth.UserId}", MemberFields())
        };
        await CommitAsync(writes, auth.IdToken).ConfigureAwait(false);
    }

    private async Task JoinGroupAsync(string code, AuthSession auth)
    {
        using var content = JsonContent(new { fields = MemberFields() });
        using var request = AuthenticatedRequest(HttpMethod.Patch, DocumentEndpoint($"syncGroups/{code}/members/{auth.UserId}"), auth.IdToken, content);
        using var response = await _client.SendAsync(request).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
    }

    private object MemberFields() => new
    {
        deviceId = StringValue(DeviceId),
        platform = StringValue("windows"),
        joinedAt = TimestampValue(DateTime.UtcNow)
    };

    private async Task UploadClaudeAsync(string code, IReadOnlyList<UsageEvent> events, string idToken)
    {
        var cutoff = UploadCutoff("lastUploadedClaudeEventAt_" + code);
        var selected = events.Where(e => e.Timestamp.ToUniversalTime() >= cutoff).OrderBy(e => e.Timestamp).ToArray();
        if (selected.Length == 0) return;
        var writes = selected.Select(e => WriteDocument(code, "claudeEvents", DocumentId(DeviceId, e.SessionId, e.Timestamp), ClaudeFields(e))).ToArray();
        await CommitInBatchesAsync(writes, idToken).ConfigureAwait(false);
        SaveWatermark("lastUploadedClaudeEventAt_" + code, selected.Max(e => e.Timestamp));
    }

    private async Task UploadCodexAsync(string code, IReadOnlyList<CodexUsageEvent> events, string idToken)
    {
        var cutoff = UploadCutoff("lastUploadedCodexEventAt_" + code);
        var selected = events.Where(e => e.Timestamp.ToUniversalTime() >= cutoff).OrderBy(e => e.Timestamp).ToArray();
        if (selected.Length == 0) return;
        var writes = selected.Select(e => WriteDocument(code, "codexEvents", DocumentId(DeviceId, e.SessionId, e.Timestamp), CodexFields(e))).ToArray();
        await CommitInBatchesAsync(writes, idToken).ConfigureAwait(false);
        SaveWatermark("lastUploadedCodexEventAt_" + code, selected.Max(e => e.Timestamp));
    }

    private async Task UploadOllamaAsync(string code, IReadOnlyList<OllamaUsageEvent> events, string idToken)
    {
        var cutoff = UploadCutoff("lastUploadedOllamaEventAt_" + code);
        var selected = events.Where(e => e.Timestamp.ToUniversalTime() >= cutoff).OrderBy(e => e.Timestamp).ToArray();
        if (selected.Length == 0) return;
        var writes = selected.Select(e => WriteDocument(code, "ollamaEvents", DocumentId(DeviceId, e.RequestId, e.Timestamp), OllamaFields(e))).ToArray();
        await CommitInBatchesAsync(writes, idToken).ConfigureAwait(false);
        SaveWatermark("lastUploadedOllamaEventAt_" + code, selected.Max(e => e.Timestamp));
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

    private async Task CommitInBatchesAsync(IReadOnlyList<object> writes, string idToken)
    {
        for (var offset = 0; offset < writes.Count; offset += UploadBatchSize)
        {
            await CommitAsync(writes.Skip(offset).Take(UploadBatchSize).ToArray(), idToken).ConfigureAwait(false);
        }
    }

    private async Task CommitAsync(IReadOnlyList<object> writes, string idToken)
    {
        using var content = JsonContent(new { writes });
        using var request = AuthenticatedRequest(HttpMethod.Post, Endpoint(":commit"), idToken, content);
        using var response = await _client.SendAsync(request).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
    }

    private async Task<IReadOnlyList<UsageEvent>> QueryClaudeAsync(string code, DateTime cutoff, string idToken)
    {
        using var response = await RunQueryAsync(code, "claudeEvents", cutoff, idToken).ConfigureAwait(false);
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

    private async Task<IReadOnlyList<CodexUsageEvent>> QueryCodexAsync(string code, DateTime cutoff, string idToken)
    {
        using var response = await RunQueryAsync(code, "codexEvents", cutoff, idToken).ConfigureAwait(false);
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

    private async Task<IReadOnlyList<OllamaUsageEvent>> QueryOllamaAsync(string code, DateTime cutoff, string idToken)
    {
        using var response = await RunQueryAsync(code, "ollamaEvents", cutoff, idToken).ConfigureAwait(false);
        var result = new List<OllamaUsageEvent>();
        foreach (var fields in DocumentFields(response))
        {
            if (StringValue(fields, "deviceId") == DeviceId || !MapValue(fields, "event", out var e)) continue;
            if (TryDate(e, "timestamp", out var timestamp))
            {
                var source = string.Equals(StringValue(e, "source"), "cloud", StringComparison.OrdinalIgnoreCase)
                    ? OllamaUsageSource.Cloud : OllamaUsageSource.Local;
                result.Add(new OllamaUsageEvent(timestamp, StringValue(e, "model", "unknown"), IntValue(e, "inputTokens"),
                    IntValue(e, "outputTokens"), IntValue(e, "totalDurationNanoseconds"), source, StringValue(e, "requestId")));
            }
        }
        return result;
    }

    private async Task<JsonDocument> RunQueryAsync(string code, string collection, DateTime cutoff, string idToken)
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
        using var request = AuthenticatedRequest(HttpMethod.Post, GroupEndpoint(code, ":runQuery"), idToken, content);
        using var response = await _client.SendAsync(request).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        return JsonDocument.Parse(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
    }

    private async Task<AuthSession> GetAuthAsync()
    {
        if (_idToken is not null && _userId is not null && _idTokenExpiresAt > DateTimeOffset.UtcNow.AddMinutes(5))
            return new AuthSession(_idToken, _userId);

        await _authGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_idToken is not null && _userId is not null && _idTokenExpiresAt > DateTimeOffset.UtcNow.AddMinutes(5))
                return new AuthSession(_idToken, _userId);

            var protectedRefreshToken = _settings.GetString(RefreshTokenSetting);
            var refreshToken = protectedRefreshToken is null ? null : WindowsCredentialProtector.Unprotect(protectedRefreshToken);
            AuthResponse? response = null;
            var createdNewIdentity = false;
            if (!string.IsNullOrWhiteSpace(refreshToken)) response = await TryRefreshAuthAsync(refreshToken).ConfigureAwait(false);
            if (response is null)
            {
                _settings.Remove(RefreshTokenSetting);
                response = await SignInAnonymouslyAsync().ConfigureAwait(false);
                createdNewIdentity = true;
            }

            _idToken = response.IdToken;
            _userId = response.UserId;
            _idTokenExpiresAt = DateTimeOffset.UtcNow.AddSeconds(Math.Max(60, response.ExpiresInSeconds));
            var protectedToken = WindowsCredentialProtector.Protect(response.RefreshToken)
                ?? throw new InvalidOperationException("Windows could not securely store the Firebase credential.");
            _settings.SetString(RefreshTokenSetting, protectedToken);
            var session = new AuthSession(_idToken, _userId);
            if (createdNewIdentity && GroupId is { } existingGroup)
            {
                try
                {
                    await JoinGroupAsync(existingGroup, session).ConfigureAwait(false);
                }
                catch
                {
                    _idToken = null;
                    _userId = null;
                    throw;
                }
            }
            return session;
        }
        finally
        {
            _authGate.Release();
        }
    }

    private async Task<AuthResponse> SignInAnonymouslyAsync()
    {
        using var content = JsonContent(new { returnSecureToken = true });
        using var response = await _client.PostAsync(AuthEndpoint("https://identitytoolkit.googleapis.com/v1/accounts:signUp"), content).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
        return ParseAuthResponse(json.RootElement, false);
    }

    private async Task<AuthResponse?> TryRefreshAuthAsync(string refreshToken)
    {
        try
        {
            using var content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = refreshToken
            });
            using var response = await _client.PostAsync(AuthEndpoint("https://securetoken.googleapis.com/v1/token"), content).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
            return ParseAuthResponse(json.RootElement, true);
        }
        catch
        {
            return null;
        }
    }

    private static AuthResponse ParseAuthResponse(JsonElement root, bool snakeCase)
    {
        string Value(string camel, string snake) => root.GetProperty(snakeCase ? snake : camel).GetString() ?? throw new InvalidDataException("Firebase Authentication returned an incomplete response.");
        var expiresText = Value("expiresIn", "expires_in");
        return new AuthResponse(
            Value("idToken", "id_token"), Value("refreshToken", "refresh_token"), Value("localId", "user_id"),
            long.TryParse(expiresText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds) ? seconds : 3600);
    }

    private IEnumerable<JsonElement> DocumentFields(JsonDocument document)
    {
        foreach (var row in document.RootElement.EnumerateArray())
        {
            if (row.TryGetProperty("document", out var doc) && doc.TryGetProperty("fields", out var fields)) yield return fields;
        }
    }

    private object WriteDocument(string code, string collection, string documentId, object fields) =>
        WriteDocumentByPath($"syncGroups/{code}/{collection}/{documentId}", fields);

    private object WriteDocumentByPath(string path, object fields) => new
    {
        update = new { name = $"projects/{_config!.ProjectId}/databases/(default)/documents/{path}", fields }
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

    private object OllamaFields(OllamaUsageEvent e) => new
    {
        deviceId = StringValue(DeviceId),
        @event = MapValue(new
        {
            timestamp = TimestampValue(e.Timestamp), model = StringValue(e.Model), inputTokens = IntValue(e.InputTokens),
            outputTokens = IntValue(e.OutputTokens), totalDurationNanoseconds = IntValue(e.TotalDurationNanoseconds),
            source = StringValue(e.Source == OllamaUsageSource.Cloud ? "cloud" : "local"), requestId = StringValue(e.RequestId)
        })
    };

    private static HttpRequestMessage AuthenticatedRequest(HttpMethod method, string uri, string idToken, HttpContent? content = null)
    {
        var request = new HttpRequestMessage(method, uri) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", idToken);
        return request;
    }

    private string AuthEndpoint(string baseUri) => $"{baseUri}?key={Uri.EscapeDataString(_config!.ApiKey)}";
    private string Endpoint(string suffix) => $"https://firestore.googleapis.com/v1/projects/{Uri.EscapeDataString(_config!.ProjectId)}/databases/(default)/documents{suffix}?key={Uri.EscapeDataString(_config.ApiKey)}";
    private string DocumentEndpoint(string path) => $"https://firestore.googleapis.com/v1/projects/{Uri.EscapeDataString(_config!.ProjectId)}/databases/(default)/documents/{path}?key={Uri.EscapeDataString(_config.ApiKey)}";
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

    private static string GeneratePairingCode()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        var chars = new char[16];
        for (var i = 0; i < chars.Length; i++) chars[i] = Alphabet[bytes[i] % Alphabet.Length];
        return new string(chars);
    }

    public static string? NormalizePairingCode(string? code)
    {
        var normalized = code?.Trim().ToUpperInvariant().Replace("-", "").Replace(" ", "");
        return normalized is not null && PairingCodePattern.IsMatch(normalized) ? normalized : null;
    }

    public static string FormatPairingCode(string code) => string.Join("-", Enumerable.Range(0, 4).Select(i => code.Substring(i * 4, 4)));

    public void Dispose()
    {
        _disposed = true;
        _pollTimer.Dispose();
        _client.Dispose();
        _syncGate.Dispose();
        _authGate.Dispose();
    }

    private sealed record AuthSession(string IdToken, string UserId);
    private sealed record AuthResponse(string IdToken, string RefreshToken, string UserId, long ExpiresInSeconds);

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
                return string.IsNullOrWhiteSpace(projectId) || projectId == "disabled" ||
                       string.IsNullOrWhiteSpace(apiKey) || apiKey == "disabled"
                    ? null : new FirebaseConfig(projectId, apiKey);
            }
            catch { return null; }
        }
    }
}
