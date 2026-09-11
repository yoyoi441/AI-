using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using TokenMihariban.Models;

namespace TokenMihariban.Parsing;

/// <summary>
/// Parses Codex CLI's local session transcripts (`~/.codex/sessions/**/rollout-*.jsonl`).
/// Each line is a standalone JSON event. The model in use is announced on
/// `turn_context` lines and applies to `token_count` events that follow, so parsing is
/// stateful within a single call (unlike JsonlParser, where every line is self-contained).
/// </summary>
public static class CodexJsonlParser
{
    public sealed class ParseResult
    {
        public List<CodexUsageEvent> Events { get; } = new();
        public CodexRateLimitWindow? LatestPrimaryWindow { get; set; }
        public CodexRateLimitWindow? LatestSecondaryWindow { get; set; }
        public DateTime? LatestWindowEventTimestamp { get; set; }
        public long NewOffset { get; set; }
    }

    public static ParseResult ParseFile(string path, string sessionId, long byteOffset = 0)
    {
        var result = new ParseResult { NewOffset = byteOffset };

        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        stream.Seek(byteOffset, SeekOrigin.Begin);
        var remaining = stream.Length - byteOffset;
        if (remaining <= 0) return result;

        using var reader = new BinaryReader(stream);
        var data = reader.ReadBytes((int)remaining);
        var lastNewline = Array.LastIndexOf(data, (byte)'\n');
        if (lastNewline < 0) return result;

        var completeLength = lastNewline + 1;
        result.NewOffset = byteOffset + completeLength;

        var content = Encoding.UTF8.GetString(data, 0, completeLength);
        var currentModel = "unknown";
        // Set once from the file's `session_meta` line (always the first line, so a full
        // history parse from offset 0 always sees it). A batch that starts mid-session
        // during incremental parsing won't see it and falls back to "unknown" — same
        // accepted limitation as `currentModel` above.
        var currentProjectPath = "unknown";

        foreach (var rawLine in content.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0) continue;

            JsonDocument doc;
            try { doc = JsonDocument.Parse(line); }
            catch (JsonException) { continue; }

            using (doc)
            {
                var root = doc.RootElement;
                var type = GetString(root, "type");
                if (!root.TryGetProperty("payload", out var payload)) continue;

                if (type == "session_meta")
                {
                    var cwd = GetString(payload, "cwd");
                    if (cwd is not null) currentProjectPath = cwd;
                    continue;
                }

                if (type == "turn_context")
                {
                    var model = GetString(payload, "model");
                    if (model is not null) currentModel = model;
                    continue;
                }

                if (type != "event_msg" || GetString(payload, "type") != "token_count") continue;
                if (!payload.TryGetProperty("info", out var info)) continue;
                if (!info.TryGetProperty("last_token_usage", out var usage)) continue;

                var timestampString = GetString(root, "timestamp");
                if (timestampString is null || !JsonlParser.TryParseDate(timestampString, out var date)) continue;

                result.Events.Add(new CodexUsageEvent(
                    Timestamp: date,
                    Model: currentModel,
                    InputTokens: GetLong(usage, "input_tokens"),
                    CachedInputTokens: GetLong(usage, "cached_input_tokens"),
                    OutputTokens: GetLong(usage, "output_tokens"),
                    ReasoningOutputTokens: GetLong(usage, "reasoning_output_tokens"),
                    SessionId: sessionId,
                    ProjectPath: currentProjectPath
                ));

                if (payload.TryGetProperty("rate_limits", out var rateLimits) &&
                    IsGeneralCodexLimit(GetString(rateLimits, "limit_id")))
                {
                    var planType = GetString(rateLimits, "plan_type");
                    var primary = ParseWindow(rateLimits, "primary", planType);
                    var secondary = ParseWindow(rateLimits, "secondary", planType);
                    if (primary is not null) result.LatestPrimaryWindow = primary;
                    if (secondary is not null) result.LatestSecondaryWindow = secondary;
                    if (primary is not null || secondary is not null) result.LatestWindowEventTimestamp = date;
                }
            }
        }

        return result;
    }

    /// <summary>
    /// Codex writes account-wide and model-specific quota families to the same log.
    /// Only the account-wide <c>codex</c> family belongs in the main gauge; otherwise
    /// a newly emitted, unused model allowance can incorrectly replace it with 0%.
    /// Older clients did not include a limit id, so a missing value remains accepted.
    /// </summary>
    private static bool IsGeneralCodexLimit(string? limitId) =>
        string.IsNullOrWhiteSpace(limitId) || string.Equals(limitId.Trim(), "codex", StringComparison.OrdinalIgnoreCase);

    private static CodexRateLimitWindow? ParseWindow(JsonElement rateLimits, string propertyName, string? planType)
    {
        if (!rateLimits.TryGetProperty(propertyName, out var window) || window.ValueKind != JsonValueKind.Object) return null;
        if (!window.TryGetProperty("used_percent", out var usedPercentEl) || usedPercentEl.ValueKind != JsonValueKind.Number) return null;
        if (!window.TryGetProperty("window_minutes", out var windowMinutesEl) || windowMinutesEl.ValueKind != JsonValueKind.Number) return null;
        if (!window.TryGetProperty("resets_at", out var resetsAtEl) || resetsAtEl.ValueKind != JsonValueKind.Number) return null;

        var resetsAtUnix = resetsAtEl.GetDouble();
        var resetsAt = DateTimeOffset.FromUnixTimeMilliseconds((long)(resetsAtUnix * 1000)).UtcDateTime;
        return new CodexRateLimitWindow(usedPercentEl.GetDouble(), windowMinutesEl.GetInt64(), resetsAt, planType);
    }

    private static string? GetString(JsonElement element, string propertyName)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.String)
        {
            return prop.GetString();
        }
        return null;
    }

    private static long GetLong(JsonElement element, string propertyName)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.Number)
        {
            return prop.GetInt64();
        }
        return 0;
    }
}
