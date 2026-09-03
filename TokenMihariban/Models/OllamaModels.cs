using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace TokenMihariban.Models;

public enum OllamaUsageSource { Local, Cloud }

public sealed record OllamaUsageEvent(
    DateTime Timestamp,
    string Model,
    long InputTokens,
    long OutputTokens,
    long TotalDurationNanoseconds,
    OllamaUsageSource Source,
    string RequestId)
{
    public long TotalTokens => InputTokens + OutputTokens;
}

public sealed class OllamaModelBreakdown
{
    public required string Model { get; init; }
    public long LocalInputTokens { get; set; }
    public long LocalOutputTokens { get; set; }
    public long CloudInputTokens { get; set; }
    public long CloudOutputTokens { get; set; }
    public double? CloudEstimatedCostUSD { get; set; }
    public long TotalTokens => LocalInputTokens + LocalOutputTokens + CloudInputTokens + CloudOutputTokens;
}

public sealed class OllamaSnapshot
{
    public DateTime GeneratedAt { get; init; }
    public long TodayTotalTokens { get; init; }
    public long TodayLocalTokens { get; init; }
    public long TodayCloudTokens { get; init; }
    public double TodayCloudEstimatedCostUSD { get; init; }
    public IReadOnlyList<OllamaModelBreakdown> TodayModelBreakdown { get; init; } = Array.Empty<OllamaModelBreakdown>();
    public IReadOnlyList<HourlyUsagePoint> HourlyTokensToday { get; init; } = Array.Empty<HourlyUsagePoint>();
    public IReadOnlyList<DailyUsagePoint> DailyTokensLast7Days { get; init; } = Array.Empty<DailyUsagePoint>();
    public long Last7DaysTotalTokens { get; init; }
    public double DailyTokenTarget { get; init; }
    public string ColorHex { get; init; } = "#F97316";
    public double? TargetFraction => DailyTokenTarget > 0 ? Math.Clamp(TodayTotalTokens / DailyTokenTarget, 0, 1) : null;
    public bool HasUnpricedCloudModelToday => TodayModelBreakdown.Any(x => x.CloudInputTokens + x.CloudOutputTokens > 0 && x.CloudEstimatedCostUSD is null);

    public static OllamaSnapshot Empty { get; } = new() { GeneratedAt = DateTime.UnixEpoch };
}

public static class OllamaUsageComputer
{
    public static double? EstimatedCloudCostUSD(string model, long inputTokens, long outputTokens)
    {
        return OllamaCloudPricing.TryGet(model, out var pricing)
            ? inputTokens / 1_000_000d * pricing.Input + outputTokens / 1_000_000d * pricing.Output
            : null;
    }

    public static OllamaSnapshot Compute(IReadOnlyList<OllamaUsageEvent> events, double dailyTokenTarget, string colorHex, DateTime? nowValue = null)
    {
        var now = nowValue ?? DateTime.Now;
        var todayStart = now.Date;
        var sevenDaysAgo = now.AddDays(-7);
        var today = events.Where(x => x.Timestamp.ToLocalTime() >= todayStart && x.Timestamp.ToLocalTime() <= now).ToList();
        var recent = events.Where(x => x.Timestamp.ToLocalTime() >= sevenDaysAgo && x.Timestamp.ToLocalTime() <= now).ToList();
        var breakdown = new Dictionary<string, OllamaModelBreakdown>(StringComparer.OrdinalIgnoreCase);

        foreach (var usage in today)
        {
            if (!breakdown.TryGetValue(usage.Model, out var row))
            {
                row = new OllamaModelBreakdown { Model = usage.Model };
                breakdown[usage.Model] = row;
            }
            if (usage.Source == OllamaUsageSource.Cloud)
            {
                row.CloudInputTokens += usage.InputTokens;
                row.CloudOutputTokens += usage.OutputTokens;
            }
            else
            {
                row.LocalInputTokens += usage.InputTokens;
                row.LocalOutputTokens += usage.OutputTokens;
            }
        }

        var cost = 0.0;
        foreach (var row in breakdown.Values)
        {
            if (row.CloudInputTokens + row.CloudOutputTokens == 0) continue;
            row.CloudEstimatedCostUSD = EstimatedCloudCostUSD(row.Model, row.CloudInputTokens, row.CloudOutputTokens);
            if (row.CloudEstimatedCostUSD is null) continue;
            cost += row.CloudEstimatedCostUSD.Value;
        }

        return new OllamaSnapshot
        {
            GeneratedAt = now,
            TodayLocalTokens = today.Where(x => x.Source == OllamaUsageSource.Local).Sum(x => x.TotalTokens),
            TodayCloudTokens = today.Where(x => x.Source == OllamaUsageSource.Cloud).Sum(x => x.TotalTokens),
            TodayTotalTokens = today.Sum(x => x.TotalTokens),
            TodayCloudEstimatedCostUSD = cost,
            TodayModelBreakdown = breakdown.Values.OrderBy(x => x.Model, StringComparer.OrdinalIgnoreCase).ToArray(),
            HourlyTokensToday = today.GroupBy(x => new DateTime(x.Timestamp.ToLocalTime().Year, x.Timestamp.ToLocalTime().Month, x.Timestamp.ToLocalTime().Day, x.Timestamp.ToLocalTime().Hour, 0, 0))
                .Select(x => new HourlyUsagePoint(x.Key, x.Sum(y => y.TotalTokens))).OrderBy(x => x.HourStart).ToArray(),
            DailyTokensLast7Days = recent.GroupBy(x => x.Timestamp.ToLocalTime().Date)
                .Select(x => new DailyUsagePoint(x.Key, x.Sum(y => y.TotalTokens))).OrderBy(x => x.Day).ToArray(),
            Last7DaysTotalTokens = recent.Sum(x => x.TotalTokens),
            DailyTokenTarget = dailyTokenTarget,
            ColorHex = colorHex
        };
    }
}

public static class OllamaUsageResponseParser
{
    public static OllamaUsageEvent? Parse(byte[] data, string? requestedModel, bool forceCloud, string? requestId = null, DateTime? fallbackDate = null)
    {
        var objects = new List<JsonElement>();
        try
        {
            using var doc = JsonDocument.Parse(data);
            objects.Add(doc.RootElement.Clone());
        }
        catch
        {
            var text = Encoding.UTF8.GetString(data);
            foreach (var raw in text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Reverse())
            {
                var line = raw.Trim();
                if (line.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) line = line[5..].Trim();
                if (line == "[DONE]") continue;
                try
                {
                    using var lineDoc = JsonDocument.Parse(line);
                    objects.Add(lineDoc.RootElement.Clone());
                }
                catch { }
            }
        }

        var root = objects.FirstOrDefault(x => x.ValueKind == JsonValueKind.Object &&
            (x.TryGetProperty("prompt_eval_count", out _) || x.TryGetProperty("eval_count", out _)));
        if (root.ValueKind != JsonValueKind.Object) return null;
        var input = ReadLong(root, "prompt_eval_count");
        var output = ReadLong(root, "eval_count");
        if (input <= 0 && output <= 0) return null;
        var model = ReadString(root, "model") ?? requestedModel ?? "unknown";
        var remoteHost = ReadString(root, "remote_host");
        var source = ReadString(root, "source");
        var isCloud = forceCloud || model.EndsWith(":cloud", StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrWhiteSpace(remoteHost) || string.Equals(source, "cloud", StringComparison.OrdinalIgnoreCase);
        var dateText = ReadString(root, "created_at");
        var timestamp = DateTime.TryParse(dateText, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed)
            ? parsed : fallbackDate ?? DateTime.UtcNow;
        return new OllamaUsageEvent(timestamp, model, input, output, ReadLong(root, "total_duration"),
            isCloud ? OllamaUsageSource.Cloud : OllamaUsageSource.Local, requestId ?? Guid.NewGuid().ToString());
    }

    private static long ReadLong(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value)) return 0;
        if (value.TryGetInt64(out var number)) return number;
        return value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), out number) ? number : 0;
    }

    private static string? ReadString(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}

internal static class OllamaCloudPricing
{
    internal readonly record struct Price(double Input, double Output);

    private static readonly IReadOnlyDictionary<string, Price> Prices = new Dictionary<string, Price>(StringComparer.OrdinalIgnoreCase)
    {
        ["deepseek-v4-flash"] = new(0.44, 1.32), ["deepseek-v4-pro"] = new(1.32, 3.96),
        ["gemma4"] = new(0.14, 0.40), ["glm-5.3"] = new(1.40, 4.40),
        ["glm-5.3-flash"] = new(0.15, 0.50), ["glm-5.2"] = new(1.40, 4.40),
        ["glm-5.1"] = new(1.00, 3.20), ["gpt-oss:120b"] = new(0.15, 0.60),
        ["gpt-oss:20b"] = new(0.07, 0.30), ["kimi-k3"] = new(3.00, 15.00),
        ["kimi-k2.7-code"] = new(0.95, 4.00), ["kimi-k2.6"] = new(0.95, 4.00),
        ["minimax-m3"] = new(0.60, 2.40), ["minimax-m2.7"] = new(0.30, 1.20),
        ["mistral-large-3"] = new(0.50, 1.50), ["nemotron-3-nano"] = new(0.06, 0.24),
        ["nemotron-3-super"] = new(0.015, 0.60), ["nemotron-3-ultra"] = new(0.10, 3.00),
        ["qwen3.5:397b"] = new(0.60, 3.60)
    };

    public static bool TryGet(string model, out Price price)
    {
        var key = model.ToLowerInvariant();
        if (key.EndsWith(":cloud")) key = key[..^6];
        if (key.EndsWith("-cloud")) key = key[..^6];
        return Prices.TryGetValue(key, out price);
    }
}
