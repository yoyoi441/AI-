using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using TokenMihariban.Models;

namespace TokenMihariban.Parsing;

public static class GeminiSessionParser
{
    public static IReadOnlyList<AIToolUsageEvent> Parse(byte[] data, string fallbackSessionId = "unknown")
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (doc.RootElement.ValueKind == JsonValueKind.Object)
                return ParseLegacy(doc.RootElement, fallbackSessionId);
        }
        catch { }

        var sessionId = fallbackSessionId;
        var projectPath = "unknown";
        var result = new List<AIToolUsageEvent>();
        foreach (var line in System.Text.Encoding.UTF8.GetString(data).Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                using var doc = JsonDocument.Parse(line);
                var root = doc.RootElement;
                sessionId = String(root, "sessionId") ?? sessionId;
                projectPath = FirstDirectory(root) ?? projectPath;
                if (root.TryGetProperty("$set", out var set) && set.ValueKind == JsonValueKind.Object)
                {
                    sessionId = String(set, "sessionId") ?? sessionId;
                    projectPath = FirstDirectory(set) ?? projectPath;
                    if (set.TryGetProperty("messages", out var messages) && messages.ValueKind == JsonValueKind.Array)
                        foreach (var message in messages.EnumerateArray()) if (Event(message, sessionId, projectPath) is { } usage) result.Add(usage);
                }
                if (Event(root, sessionId, projectPath) is { } parsed) result.Add(parsed);
            }
            catch { }
        }
        return result.GroupBy(x => x.EventId).Select(x => x.Last()).ToArray();
    }

    private static IReadOnlyList<AIToolUsageEvent> ParseLegacy(JsonElement root, string fallbackSessionId)
    {
        var sessionId = String(root, "sessionId") ?? fallbackSessionId;
        var projectPath = FirstDirectory(root) ?? "unknown";
        if (!root.TryGetProperty("messages", out var messages) || messages.ValueKind != JsonValueKind.Array) return Array.Empty<AIToolUsageEvent>();
        return messages.EnumerateArray().Select(x => Event(x, sessionId, projectPath)).Where(x => x is not null).Cast<AIToolUsageEvent>()
            .GroupBy(x => x.EventId).Select(x => x.Last()).ToArray();
    }

    private static AIToolUsageEvent? Event(JsonElement value, string sessionId, string projectPath)
    {
        if (String(value, "type") != "gemini" || !value.TryGetProperty("tokens", out var tokens) || tokens.ValueKind != JsonValueKind.Object) return null;
        if (!DateTime.TryParse(String(value, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var timestamp)) return null;
        var input = Integer(tokens, "input");
        var output = Integer(tokens, "output");
        var cached = Integer(tokens, "cached");
        var reasoning = Integer(tokens, "thoughts");
        var total = Integer(tokens, "total");
        if (total <= 0) total = input + output + reasoning;
        if (total <= 0) return null;
        var messageId = String(value, "id") ?? timestamp.Ticks.ToString(CultureInfo.InvariantCulture);
        return new AIToolUsageEvent(timestamp, AIToolKind.GeminiCli, "google", String(value, "model") ?? "unknown",
            input, output, cached, reasoning, total, $"gemini:{sessionId}:{messageId}", sessionId, projectPath);
    }

    private static string? FirstDirectory(JsonElement value)
    {
        if (!value.TryGetProperty("directories", out var dirs) || dirs.ValueKind != JsonValueKind.Array) return null;
        foreach (var item in dirs.EnumerateArray())
            if (item.ValueKind == JsonValueKind.String) return item.GetString();
        return null;
    }

    private static string? String(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;

    private static long Integer(JsonElement value, string name) =>
        value.TryGetProperty(name, out var item) ? Integer(item) : 0;

    private static long Integer(JsonElement value)
    {
        if (value.TryGetInt64(out var integer)) return integer;
        if (value.TryGetDouble(out var number) && double.IsFinite(number)) return (long)number;
        return value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out integer)
            ? integer : 0;
    }
}

public static class OpenCodeMessageParser
{
    public static AIToolUsageEvent? ParseMessageData(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var value = doc.RootElement;
            if (String(value, "role") != "assistant" || !value.TryGetProperty("tokens", out var tokens) ||
                !value.TryGetProperty("time", out var time) || !time.TryGetProperty("created", out var createdElement) ||
                !createdElement.TryGetDouble(out var created)) return null;
            var input = Integer(tokens, "input");
            var output = Integer(tokens, "output");
            var reasoning = Integer(tokens, "reasoning");
            var cached = tokens.TryGetProperty("cache", out var cache) ? Integer(cache, "read") : 0;
            var total = Integer(tokens, "total");
            if (total <= 0) total = input + output + reasoning;
            if (total <= 0) return null;
            var messageId = String(value, "id") ?? created.ToString(CultureInfo.InvariantCulture);
            var sessionId = String(value, "sessionID") ?? "unknown";
            var projectPath = value.TryGetProperty("path", out var path) ? String(path, "cwd") ?? "unknown" : "unknown";
            return new AIToolUsageEvent(DateTimeOffset.FromUnixTimeMilliseconds((long)created).UtcDateTime, AIToolKind.OpenCode,
                String(value, "providerID") ?? "unknown", String(value, "modelID") ?? "unknown", input, output, cached, reasoning,
                total, $"opencode:{messageId}", sessionId, projectPath);
        }
        catch { return null; }
    }

    private static string? String(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;
    private static long Integer(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(name, out var item)) return 0;
        if (item.TryGetInt64(out var integer)) return integer;
        if (item.TryGetDouble(out var number) && double.IsFinite(number)) return (long)number;
        return item.ValueKind == JsonValueKind.String && long.TryParse(item.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out integer)
            ? integer : 0;
    }
}
