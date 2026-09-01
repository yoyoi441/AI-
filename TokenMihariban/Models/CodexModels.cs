using System;
using System.Collections.Generic;

namespace TokenMihariban.Models;

/// <summary>
/// One Codex CLI turn, parsed from a `~/.codex/sessions/**/rollout-*.jsonl` transcript.
/// Unlike Claude Code, Codex reports the tokens actually spent on *this* turn directly.
/// </summary>
public sealed record CodexUsageEvent(
    DateTime Timestamp,
    string Model,
    long InputTokens,
    long CachedInputTokens,
    long OutputTokens,
    long ReasoningOutputTokens,
    string SessionId,
    string ProjectPath = "unknown")
{
    public long TotalTokens => InputTokens + OutputTokens;
}

/// <summary>A rate-limit window as reported directly by OpenAI — no estimation involved.</summary>
public sealed record CodexRateLimitWindow(double UsedPercent, long WindowMinutes, DateTime ResetsAt, string? PlanType)
{
    public double Fraction => Math.Min(1, Math.Max(0, UsedPercent / 100));
}

public sealed class CodexSnapshot
{
    public required DateTime GeneratedAt { get; init; }
    public required long TodayTotalTokens { get; init; }
    public required IReadOnlyList<ModelBreakdown> TodayModelBreakdown { get; init; }
    public IReadOnlyList<ProjectUsageEntry> TodayByProject { get; init; } = Array.Empty<ProjectUsageEntry>();
    public required IReadOnlyList<HourlyUsagePoint> HourlyTokensToday { get; init; }
    public required IReadOnlyList<DailyUsagePoint> DailyTokensLast7Days { get; init; }
    public required long Last7DaysTotalTokens { get; init; }
    public required CodexRateLimitWindow? PrimaryWindow { get; init; }
    public required CodexRateLimitWindow? SecondaryWindow { get; init; }
    public required string ColorHex { get; init; }

    public static CodexSnapshot Empty => new()
    {
        GeneratedAt = DateTime.UnixEpoch,
        TodayTotalTokens = 0,
        TodayModelBreakdown = Array.Empty<ModelBreakdown>(),
        TodayByProject = Array.Empty<ProjectUsageEntry>(),
        HourlyTokensToday = Array.Empty<HourlyUsagePoint>(),
        DailyTokensLast7Days = Array.Empty<DailyUsagePoint>(),
        Last7DaysTotalTokens = 0,
        PrimaryWindow = null,
        SecondaryWindow = null,
        ColorHex = "#22C55E"
    };
}
