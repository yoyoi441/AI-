using System;
using System.Collections.Generic;
using System.Linq;

namespace TokenMihariban.Models;

public enum AIToolKind { GeminiCli, OpenCode }

public static class AIToolKindExtensions
{
    public static string StorageValue(this AIToolKind value) => value == AIToolKind.GeminiCli ? "gemini-cli" : "opencode";
    public static string DisplayName(this AIToolKind value) => value == AIToolKind.GeminiCli ? "Gemini CLI" : "OpenCode";
    public static AIToolKind FromStorageValue(string? value) => value == "opencode" ? AIToolKind.OpenCode : AIToolKind.GeminiCli;
}

public sealed record AIToolUsageEvent(
    DateTime Timestamp,
    AIToolKind Tool,
    string Provider,
    string Model,
    long InputTokens,
    long OutputTokens,
    long CachedTokens,
    long ReasoningTokens,
    long TotalTokens,
    string EventId,
    string SessionId,
    string ProjectPath = "unknown");

public sealed record AIToolBreakdown(AIToolKind Tool, string Provider, string Model, long Tokens)
{
    public string DisplayName => $"{Tool.DisplayName()} · {(string.IsNullOrWhiteSpace(Provider) || Provider == "google" ? "" : Provider + " / ")}{Model}";
}

public sealed class AIToolSnapshot
{
    public DateTime GeneratedAt { get; init; }
    public long TodayTotalTokens { get; init; }
    public IReadOnlyList<AIToolBreakdown> TodayBreakdown { get; init; } = Array.Empty<AIToolBreakdown>();
    public IReadOnlyList<HourlyUsagePoint> HourlyTokensToday { get; init; } = Array.Empty<HourlyUsagePoint>();
    public IReadOnlyList<DailyUsagePoint> DailyTokensLast7Days { get; init; } = Array.Empty<DailyUsagePoint>();
    public long Last7DaysTotalTokens { get; init; }
    public double DailyTokenTarget { get; init; }
    public string ColorHex { get; init; } = "#8B5CF6";
    public double? TargetFraction => DailyTokenTarget > 0 ? Math.Clamp(TodayTotalTokens / DailyTokenTarget, 0, 1) : null;
    public static AIToolSnapshot Empty { get; } = new() { GeneratedAt = DateTime.UnixEpoch };
}

public static class AIToolUsageComputer
{
    public static AIToolSnapshot Compute(IReadOnlyList<AIToolUsageEvent> events, double dailyTokenTarget, string colorHex, DateTime? nowValue = null)
    {
        var now = nowValue ?? DateTime.Now;
        var deduplicated = events.GroupBy(x => x.EventId).Select(x => x.Last()).ToArray();
        var today = deduplicated.Where(x => x.Timestamp.ToLocalTime() >= now.Date && x.Timestamp.ToLocalTime() <= now).ToArray();
        var recent = deduplicated.Where(x => x.Timestamp.ToLocalTime() >= now.AddDays(-7) && x.Timestamp.ToLocalTime() <= now).ToArray();
        return new AIToolSnapshot
        {
            GeneratedAt = now,
            TodayTotalTokens = today.Sum(x => x.TotalTokens),
            TodayBreakdown = today.GroupBy(x => new { x.Tool, x.Provider, x.Model })
                .Select(x => new AIToolBreakdown(x.Key.Tool, x.Key.Provider, x.Key.Model, x.Sum(y => y.TotalTokens)))
                .OrderByDescending(x => x.Tokens).ToArray(),
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

