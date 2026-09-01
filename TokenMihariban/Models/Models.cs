using System;
using System.Collections.Generic;
using System.Linq;

namespace TokenMihariban.Models;

/// <summary>
/// One Claude Code API call, parsed from a `~/.claude/projects/**/*.jsonl` transcript
/// line. Field names match the other platform implementations so local aggregation
/// behavior stays consistent.
/// </summary>
public sealed record UsageEvent(
    DateTime Timestamp,
    string Model,
    long InputTokens,
    long OutputTokens,
    long CacheCreationTokens,
    long CacheReadTokens,
    string SessionId,
    string ProjectPath)
{
    public long TotalTokens => InputTokens + OutputTokens + CacheCreationTokens + CacheReadTokens;
}

/// <summary>
/// A contiguous 5-hour usage window, estimated from event timestamps (see
/// SessionBlockCalculator). Anthropic doesn't publish the real algorithm; treat this as
/// an estimate, matching the community "ccusage"-style heuristic used on every platform.
/// </summary>
public sealed record SessionBlock(DateTime Start, DateTime End, IReadOnlyList<UsageEvent> Events)
{
    public long TotalTokens => Events.Sum(e => e.TotalTokens);
}

public sealed class ModelBreakdown
{
    public string Model { get; init; } = "";
    public long InputTokens { get; set; }
    public long OutputTokens { get; set; }
    public long CacheCreationTokens { get; set; }
    public long CacheReadTokens { get; set; }
    public double? EstimatedCostUSD { get; set; }
}

/// <summary>Today's token total for one project directory. Mirrors the Mac/iOS/Android
/// `ProjectUsageEntry`.</summary>
public sealed record ProjectUsageEntry(string ProjectPath, long Tokens)
{
    public string DisplayName
    {
        get
        {
            var trimmed = ProjectPath.TrimEnd('/', '\\');
            var lastSlash = Math.Max(trimmed.LastIndexOf('/'), trimmed.LastIndexOf('\\'));
            return lastSlash >= 0 ? trimmed[(lastSlash + 1)..] : trimmed;
        }
    }
}

public sealed record HourlyUsagePoint(DateTime HourStart, long Tokens);

public sealed record DailyUsagePoint(DateTime Day, long Tokens);

public sealed record SessionBlockSummary(DateTime Start, DateTime End, long TotalTokens);

public enum GaugeDisplayStyle
{
    Bar,
    Ring
}

public static class GaugeDisplayStyleExtensions
{
    public static string ToStorageValue(this GaugeDisplayStyle style) => style switch
    {
        GaugeDisplayStyle.Bar => "bar",
        GaugeDisplayStyle.Ring => "ring",
        _ => "ring"
    };

    public static GaugeDisplayStyle FromStorageValue(string? raw) => raw switch
    {
        "bar" => GaugeDisplayStyle.Bar,
        _ => GaugeDisplayStyle.Ring
    };

    public static string Label(this GaugeDisplayStyle style, AppLanguage lang) => style switch
    {
        GaugeDisplayStyle.Bar => L.String("styleBar", lang),
        GaugeDisplayStyle.Ring => L.String("styleRing", lang),
        _ => ""
    };
}

/// <summary>What the menu bar/tray icon's ring or bar fraction represents.</summary>
public enum GaugeMetric
{
    TimeRemaining,
    TokenUsage
}

public static class GaugeMetricExtensions
{
    public static string ToStorageValue(this GaugeMetric metric) => metric switch
    {
        GaugeMetric.TimeRemaining => "timeRemaining",
        GaugeMetric.TokenUsage => "tokenUsage",
        _ => "timeRemaining"
    };

    public static GaugeMetric FromStorageValue(string? raw) => raw switch
    {
        "timeRemaining" => GaugeMetric.TimeRemaining,
        _ => GaugeMetric.TokenUsage
    };

    public static string Label(this GaugeMetric metric, AppLanguage lang) => metric switch
    {
        GaugeMetric.TimeRemaining => L.String("menuBarMetricTime", lang),
        GaugeMetric.TokenUsage => L.String("menuBarMetricTokenUsage", lang),
        _ => ""
    };
}

public sealed class GaugeAppearance
{
    public required string ColorHex { get; init; }
    public required bool UseGradient { get; init; }
    public required GaugeDisplayStyle Style { get; init; }

    public static GaugeAppearance Default => new()
    {
        ColorHex = "#3B82F6",
        UseGradient = true,
        Style = GaugeDisplayStyle.Ring
    };
}

public sealed class UsageSnapshot
{
    public required DateTime GeneratedAt { get; init; }
    public required long TodayTotalTokens { get; init; }
    public required double TodayEstimatedCostUSD { get; init; }
    public required IReadOnlyList<ModelBreakdown> TodayModelBreakdown { get; init; }
    public IReadOnlyList<ProjectUsageEntry> TodayByProject { get; init; } = Array.Empty<ProjectUsageEntry>();
    public required SessionBlockSummary? CurrentBlock { get; init; }
    public required long Last7DaysTotalTokens { get; init; }
    public required IReadOnlyList<HourlyUsagePoint> HourlyTokensToday { get; init; }
    public required IReadOnlyList<DailyUsagePoint> DailyTokensLast7Days { get; init; }
    public required long? HistoricalMaxBlockTokens { get; init; }
    /// <summary>How many completed blocks `HistoricalMaxBlockTokens` is drawn from — used
    /// to flag a self-based target as low-confidence when it's really just one or two
    /// blocks' worth of data. Mirrors the Mac/iOS/Android `historicalBlockCount`.</summary>
    public int HistoricalBlockCount { get; init; }
    public required double ManualBlockTokenTarget { get; init; }
    public required GaugeAppearance Appearance { get; init; }

    public long? ReferenceTokens => ManualBlockTokenTarget > 0 ? (long)ManualBlockTokenTarget : HistoricalMaxBlockTokens;

    public bool ReferenceIsLowConfidence => ManualBlockTokenTarget <= 0 && HistoricalBlockCount < 3;

    public bool HasUnpricedModelToday => TodayModelBreakdown.Any(m => m.EstimatedCostUSD is null);

    public static UsageSnapshot Empty => new()
    {
        GeneratedAt = DateTime.UnixEpoch,
        TodayTotalTokens = 0,
        TodayEstimatedCostUSD = 0,
        TodayModelBreakdown = Array.Empty<ModelBreakdown>(),
        TodayByProject = Array.Empty<ProjectUsageEntry>(),
        CurrentBlock = null,
        Last7DaysTotalTokens = 0,
        HourlyTokensToday = Array.Empty<HourlyUsagePoint>(),
        DailyTokensLast7Days = Array.Empty<DailyUsagePoint>(),
        HistoricalMaxBlockTokens = null,
        HistoricalBlockCount = 0,
        ManualBlockTokenTarget = 0,
        Appearance = GaugeAppearance.Default
    };
}

public enum AppLanguage
{
    Japanese,
    English
}

public static class AppLanguageExtensions
{
    public static string ToStorageValue(this AppLanguage lang) => lang switch
    {
        AppLanguage.Japanese => "ja",
        AppLanguage.English => "en",
        _ => "ja"
    };

    public static AppLanguage FromStorageValue(string? raw) => raw switch
    {
        "en" => AppLanguage.English,
        _ => AppLanguage.Japanese
    };

    public static string DisplayName(this AppLanguage lang) => lang switch
    {
        AppLanguage.Japanese => "日本語",
        AppLanguage.English => "English",
        _ => ""
    };
}

/// <summary>
/// A user-defined daily time-of-day range (e.g. "work hours: 9:00-18:00"), stored as
/// minutes-since-midnight — matches the Mac/iOS/Android `DailyTimeWindow` exactly.
/// </summary>
public sealed record DailyTimeWindow(int StartMinute, int EndMinute)
{
    public static DailyTimeWindow Default => new(9 * 60, 18 * 60);

    public string RangeText() => $"{StartMinute / 60:D2}:{StartMinute % 60:D2}-{EndMinute / 60:D2}:{EndMinute % 60:D2}";
}

public static class HourlyUsagePointExtensions
{
    /// <summary>
    /// Sums tokens from today's hourly buckets whose hour falls within the window.
    /// `EndMinute &lt; StartMinute` is treated as an overnight window that wraps past midnight.
    /// </summary>
    public static long TokensInWindow(this IEnumerable<HourlyUsagePoint> points, DailyTimeWindow window)
    {
        long total = 0;
        foreach (var point in points)
        {
            var minuteOfDay = point.HourStart.Hour * 60 + point.HourStart.Minute;
            bool inWindow = window.StartMinute <= window.EndMinute
                ? minuteOfDay >= window.StartMinute && minuteOfDay < window.EndMinute
                : minuteOfDay >= window.StartMinute || minuteOfDay < window.EndMinute;
            if (inWindow) total += point.Tokens;
        }
        return total;
    }
}
