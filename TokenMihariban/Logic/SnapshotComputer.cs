using System;
using System.Collections.Generic;
using System.Linq;
using TokenMihariban.Models;

namespace TokenMihariban.Logic;

/// <summary>
/// Turns a flat list of usage events into the displayable snapshot types — ported from
/// the Mac/iOS/Android `SnapshotComputer` so "today's total"/"current block" mean
/// exactly the same thing on every platform. Day/hour bucketing uses the device's local
/// timezone (`Calendar.current` on the Mac/iOS side), matching that behavior here via
/// `DateTime.ToLocalTime()`. Block-start flooring (in SessionBlockCalculator) uses UTC
/// instead — that asymmetry is intentional and preserved from the other platforms.
/// </summary>
public static class SnapshotComputer
{
    public static UsageSnapshot ComputeSnapshot(IReadOnlyList<UsageEvent> events, double manualBlockTokenTarget, GaugeAppearance appearance)
    {
        var now = DateTime.UtcNow;
        var nowLocal = now.ToLocalTime();
        var startOfToday = nowLocal.Date;
        var sevenDaysAgo = now.AddDays(-7);

        var todayEvents = events.Where(e => e.Timestamp.ToLocalTime() >= startOfToday).ToList();
        var last7DaysEvents = events.Where(e => e.Timestamp >= sevenDaysAgo).ToList();
        var last7DaysTotalTokens = last7DaysEvents.Sum(e => e.TotalTokens);
        var todayTotalTokens = todayEvents.Sum(e => e.TotalTokens);

        var breakdownByModel = new Dictionary<string, ModelBreakdown>();
        foreach (var evt in todayEvents)
        {
            if (!breakdownByModel.TryGetValue(evt.Model, out var entry))
            {
                entry = new ModelBreakdown { Model = evt.Model };
                breakdownByModel[evt.Model] = entry;
            }
            entry.InputTokens += evt.InputTokens;
            entry.OutputTokens += evt.OutputTokens;
            entry.CacheCreationTokens += evt.CacheCreationTokens;
            entry.CacheReadTokens += evt.CacheReadTokens;
        }

        double todayCost = 0;
        var breakdown = breakdownByModel.Values
            .Where(e => e.InputTokens + e.OutputTokens + e.CacheCreationTokens + e.CacheReadTokens > 0)
            .Select(e =>
            {
                var cost = PricingTable.EstimatedCostUSD(e.Model, e.InputTokens, e.OutputTokens, e.CacheCreationTokens, e.CacheReadTokens);
                e.EstimatedCostUSD = cost;
                todayCost += cost ?? 0;
                return e;
            })
            .OrderBy(e => e.Model, StringComparer.Ordinal)
            .ToList();

        var hourlyTokensToday = HourlyBuckets(todayEvents.Select(e => (e.Timestamp, e.TotalTokens)));
        var dailyTokensLast7Days = DailyBuckets(last7DaysEvents.Select(e => (e.Timestamp, e.TotalTokens)));
        var todayByProject = ProjectBuckets(todayEvents.Select(e => (e.ProjectPath, e.TotalTokens)));

        var blocks = SessionBlockCalculator.ComputeBlocks(events);
        var activeBlock = blocks.Count > 0 && now < blocks[^1].End ? blocks[^1] : null;
        var pastBlocks = activeBlock is null ? blocks : blocks.Take(blocks.Count - 1).ToList();
        long? historicalMaxBlockTokens = pastBlocks.Count > 0 ? pastBlocks.Max(b => b.TotalTokens) : null;

        var blockSummary = activeBlock is null
            ? null
            : new SessionBlockSummary(activeBlock.Start, activeBlock.End, activeBlock.TotalTokens);

        return new UsageSnapshot
        {
            GeneratedAt = now,
            TodayTotalTokens = todayTotalTokens,
            TodayEstimatedCostUSD = todayCost,
            TodayModelBreakdown = breakdown,
            TodayByProject = todayByProject,
            CurrentBlock = blockSummary,
            Last7DaysTotalTokens = last7DaysTotalTokens,
            HourlyTokensToday = hourlyTokensToday,
            DailyTokensLast7Days = dailyTokensLast7Days,
            HistoricalMaxBlockTokens = historicalMaxBlockTokens,
            HistoricalBlockCount = pastBlocks.Count,
            ManualBlockTokenTarget = manualBlockTokenTarget,
            Appearance = appearance
        };
    }

    public static CodexSnapshot ComputeCodexSnapshot(
        IReadOnlyList<CodexUsageEvent> events,
        CodexRateLimitWindow? primaryWindow,
        CodexRateLimitWindow? secondaryWindow,
        string colorHex)
    {
        var now = DateTime.UtcNow;
        var nowLocal = now.ToLocalTime();
        var startOfToday = nowLocal.Date;
        var sevenDaysAgo = now.AddDays(-7);

        var todayEvents = events.Where(e => e.Timestamp.ToLocalTime() >= startOfToday).ToList();
        var last7DaysEvents = events.Where(e => e.Timestamp >= sevenDaysAgo).ToList();
        var last7DaysTotalTokens = last7DaysEvents.Sum(e => e.TotalTokens);
        var todayTotalTokens = todayEvents.Sum(e => e.TotalTokens);

        var breakdownByModel = new Dictionary<string, ModelBreakdown>();
        foreach (var evt in todayEvents)
        {
            if (!breakdownByModel.TryGetValue(evt.Model, out var entry))
            {
                entry = new ModelBreakdown { Model = evt.Model };
                breakdownByModel[evt.Model] = entry;
            }
            entry.InputTokens += evt.InputTokens;
            entry.OutputTokens += evt.OutputTokens;
            entry.CacheCreationTokens += evt.CachedInputTokens;
        }

        var breakdown = breakdownByModel.Values
            .Where(e => e.InputTokens + e.OutputTokens > 0)
            .OrderBy(e => e.Model, StringComparer.Ordinal)
            .ToList();

        var hourlyTokensToday = HourlyBuckets(todayEvents.Select(e => (e.Timestamp, e.TotalTokens)));
        var dailyTokensLast7Days = DailyBuckets(last7DaysEvents.Select(e => (e.Timestamp, e.TotalTokens)));
        var todayByProject = ProjectBuckets(todayEvents.Select(e => (e.ProjectPath, e.TotalTokens)));

        return new CodexSnapshot
        {
            GeneratedAt = now,
            TodayTotalTokens = todayTotalTokens,
            TodayModelBreakdown = breakdown,
            TodayByProject = todayByProject,
            HourlyTokensToday = hourlyTokensToday,
            DailyTokensLast7Days = dailyTokensLast7Days,
            Last7DaysTotalTokens = last7DaysTotalTokens,
            PrimaryWindow = primaryWindow,
            SecondaryWindow = secondaryWindow,
            ColorHex = colorHex
        };
    }

    private static List<HourlyUsagePoint> HourlyBuckets(IEnumerable<(DateTime Timestamp, long Tokens)> events)
    {
        var totalsByHour = new Dictionary<DateTime, long>();
        foreach (var (timestamp, tokens) in events)
        {
            var local = timestamp.ToLocalTime();
            var hourStart = new DateTime(local.Year, local.Month, local.Day, local.Hour, 0, 0, DateTimeKind.Local);
            totalsByHour[hourStart] = totalsByHour.GetValueOrDefault(hourStart) + tokens;
        }
        return totalsByHour
            .Select(kv => new HourlyUsagePoint(kv.Key, kv.Value))
            .OrderBy(p => p.HourStart)
            .ToList();
    }

    private static List<DailyUsagePoint> DailyBuckets(IEnumerable<(DateTime Timestamp, long Tokens)> events)
    {
        var totalsByDay = new Dictionary<DateTime, long>();
        foreach (var (timestamp, tokens) in events)
        {
            var day = timestamp.ToLocalTime().Date;
            totalsByDay[day] = totalsByDay.GetValueOrDefault(day) + tokens;
        }
        return totalsByDay
            .Select(kv => new DailyUsagePoint(kv.Key, kv.Value))
            .OrderBy(p => p.Day)
            .ToList();
    }

    private static List<ProjectUsageEntry> ProjectBuckets(IEnumerable<(string ProjectPath, long Tokens)> events)
    {
        var totalsByProject = new Dictionary<string, long>();
        foreach (var (projectPath, tokens) in events)
        {
            totalsByProject[projectPath] = totalsByProject.GetValueOrDefault(projectPath) + tokens;
        }
        return totalsByProject
            .Select(kv => new ProjectUsageEntry(kv.Key, kv.Value))
            .OrderByDescending(p => p.Tokens)
            .ToList();
    }
}
