using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using TokenMihariban.Models;

namespace TokenMihariban.Parsing;

/// <summary>
/// Parses Claude Code's local session transcripts (`~/.claude/projects/**/*.jsonl`).
/// Each line is a standalone JSON object; only assistant turns carry a `usage` block,
/// so every other line (user turns, tool results, summaries, ...) is skipped.
/// </summary>
public static class JsonlParser
{
    /// <summary>Decodes a single JSONL line into a UsageEvent, or null if it isn't a usage-bearing assistant turn.</summary>
    public static UsageEvent? ParseLine(string line)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0) return null;

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(trimmed);
        }
        catch (JsonException)
        {
            return null;
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (!TryGetString(root, "type", out var type) || type != "assistant") return null;
            if (!root.TryGetProperty("message", out var message)) return null;
            if (!message.TryGetProperty("usage", out var usage)) return null;
            if (!TryGetString(root, "timestamp", out var timestampString)) return null;
            if (!TryParseDate(timestampString, out var date)) return null;

            var model = TryGetString(message, "model", out var m) ? m : "unknown";
            var sessionId = TryGetString(root, "sessionId", out var sid) ? sid : "unknown";
            var cwd = TryGetString(root, "cwd", out var c) ? c : "unknown";

            return new UsageEvent(
                Timestamp: date,
                Model: model,
                InputTokens: GetLong(usage, "input_tokens"),
                OutputTokens: GetLong(usage, "output_tokens"),
                CacheCreationTokens: GetLong(usage, "cache_creation_input_tokens"),
                CacheReadTokens: GetLong(usage, "cache_read_input_tokens"),
                SessionId: sessionId,
                ProjectPath: cwd
            );
        }
    }

    /// <summary>
    /// Reads a log file starting at <paramref name="byteOffset"/>, returning newly
    /// parsed events and the byte offset to resume from next time. Only complete lines
    /// (ending in \n) are consumed; a trailing partial line (still being written by
    /// Claude Code) is left for the next call so it never gets split across two reads.
    /// </summary>
    public static (List<UsageEvent> Events, long NewOffset) ParseFile(string path, long byteOffset = 0)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        stream.Seek(byteOffset, SeekOrigin.Begin);
        using var reader = new BinaryReader(stream);
        var remaining = stream.Length - byteOffset;
        if (remaining <= 0) return (new List<UsageEvent>(), byteOffset);

        var data = reader.ReadBytes((int)remaining);
        var lastNewline = Array.LastIndexOf(data, (byte)'\n');
        if (lastNewline < 0) return (new List<UsageEvent>(), byteOffset);

        var completeLength = lastNewline + 1;
        var newOffset = byteOffset + completeLength;

        var events = new List<UsageEvent>();
        var content = Encoding.UTF8.GetString(data, 0, completeLength);
        foreach (var line in content.Split('\n'))
        {
            var evt = ParseLine(line);
            if (evt is not null) events.Add(evt);
        }
        return (events, newOffset);
    }

    private static bool TryGetString(JsonElement element, string propertyName, out string value)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.String)
        {
            value = prop.GetString() ?? "";
            return true;
        }
        value = "";
        return false;
    }

    private static long GetLong(JsonElement element, string propertyName)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.Number)
        {
            return prop.GetInt64();
        }
        return 0;
    }

    internal static bool TryParseDate(string s, out DateTime date)
    {
        if (DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out date))
        {
            date = DateTime.SpecifyKind(date, DateTimeKind.Utc);
            return true;
        }
        date = default;
        return false;
    }
}
