using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using TokenMihariban.Models;

namespace TokenMihariban.Logic;

/// <summary>
/// One Claude Code, Codex, or Ollama call, flattened into a single exportable row.
/// Port of the Mac/iOS/Android `UsageExportRow` — kept as raw per-event rows (not
/// pre-aggregated by day/model) so a spreadsheet or script on the receiving end can
/// group/pivot however the user actually needs.
/// </summary>
public sealed record UsageExportRow(
    DateTime Timestamp,
    string Provider,
    string Model,
    string ProjectPath,
    string SessionId,
    long InputTokens,
    long OutputTokens,
    long CacheCreationTokens,
    long CacheReadTokens,
    long TotalTokens,
    double? EstimatedCostUSD);

/// <summary>
/// Builds an export of raw usage events for a date range, for expense reports or
/// personal analysis outside the app. Port of the Mac/iOS/Android `UsageExporter`.
/// </summary>
public static class UsageExporter
{
    public static List<UsageExportRow> Rows(IReadOnlyList<UsageEvent> claudeEvents, IReadOnlyList<CodexUsageEvent> codexEvents, IReadOnlyList<OllamaUsageEvent> ollamaEvents, DateTime start, DateTime end)
    {
        var claudeRows = claudeEvents
            .Where(e => e.Timestamp >= start && e.Timestamp <= end)
            .Select(e => new UsageExportRow(
                e.Timestamp,
                "Claude Code",
                e.Model,
                e.ProjectPath,
                e.SessionId,
                e.InputTokens,
                e.OutputTokens,
                e.CacheCreationTokens,
                e.CacheReadTokens,
                e.TotalTokens,
                PricingTable.EstimatedCostUSD(e.Model, e.InputTokens, e.OutputTokens, e.CacheCreationTokens, e.CacheReadTokens)));

        var codexRows = codexEvents
            .Where(e => e.Timestamp >= start && e.Timestamp <= end)
            .Select(e => new UsageExportRow(
                e.Timestamp,
                "Codex",
                e.Model,
                e.ProjectPath,
                e.SessionId,
                e.InputTokens,
                e.OutputTokens,
                e.CachedInputTokens,
                0,
                e.TotalTokens,
                null));

        var ollamaRows = ollamaEvents
            .Where(e => e.Timestamp >= start && e.Timestamp <= end)
            .Select(e => new UsageExportRow(
                e.Timestamp,
                e.Source == OllamaUsageSource.Cloud ? "Ollama Cloud" : "Ollama Local",
                e.Model,
                "",
                e.RequestId,
                e.InputTokens,
                e.OutputTokens,
                0,
                0,
                e.TotalTokens,
                e.Source == OllamaUsageSource.Cloud ? OllamaUsageComputer.EstimatedCloudCostUSD(e.Model, e.InputTokens, e.OutputTokens) : null));

        return claudeRows.Concat(codexRows).Concat(ollamaRows).OrderBy(r => r.Timestamp).ToList();
    }

    public static string Csv(IReadOnlyList<UsageExportRow> rows)
    {
        var sb = new StringBuilder();
        sb.AppendLine("timestamp,provider,model,project,sessionId,inputTokens,outputTokens,cacheCreationTokens,cacheReadTokens,totalTokens,estimatedCostUSD");
        foreach (var row in rows)
        {
            var cost = row.EstimatedCostUSD?.ToString("F4", CultureInfo.InvariantCulture) ?? "";
            var fields = new[]
            {
                row.Timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                row.Provider,
                row.Model,
                row.ProjectPath,
                row.SessionId,
                row.InputTokens.ToString(CultureInfo.InvariantCulture),
                row.OutputTokens.ToString(CultureInfo.InvariantCulture),
                row.CacheCreationTokens.ToString(CultureInfo.InvariantCulture),
                row.CacheReadTokens.ToString(CultureInfo.InvariantCulture),
                row.TotalTokens.ToString(CultureInfo.InvariantCulture),
                cost
            };
            sb.AppendLine(string.Join(",", fields.Select(CsvField)));
        }
        return sb.ToString();
    }

    private static string CsvField(string value)
    {
        if (!value.Contains(',') && !value.Contains('"') && !value.Contains('\n')) return value;
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }

    public static string Json(IReadOnlyList<UsageExportRow> rows)
    {
        var sb = new StringBuilder();
        sb.Append("[\n");
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var cost = row.EstimatedCostUSD?.ToString(CultureInfo.InvariantCulture) ?? "null";
            sb.Append("  {\n");
            sb.Append($"    \"timestamp\": \"{row.Timestamp.ToUniversalTime():yyyy-MM-ddTHH:mm:ssZ}\",\n");
            sb.Append($"    \"provider\": \"{JsonEscape(row.Provider)}\",\n");
            sb.Append($"    \"model\": \"{JsonEscape(row.Model)}\",\n");
            sb.Append($"    \"projectPath\": \"{JsonEscape(row.ProjectPath)}\",\n");
            sb.Append($"    \"sessionId\": \"{JsonEscape(row.SessionId)}\",\n");
            sb.Append($"    \"inputTokens\": {row.InputTokens},\n");
            sb.Append($"    \"outputTokens\": {row.OutputTokens},\n");
            sb.Append($"    \"cacheCreationTokens\": {row.CacheCreationTokens},\n");
            sb.Append($"    \"cacheReadTokens\": {row.CacheReadTokens},\n");
            sb.Append($"    \"totalTokens\": {row.TotalTokens},\n");
            sb.Append($"    \"estimatedCostUSD\": {cost}\n");
            sb.Append(i == rows.Count - 1 ? "  }\n" : "  },\n");
        }
        sb.Append(']');
        return sb.ToString();
    }

    private static string JsonEscape(string value) =>
        value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");
}
