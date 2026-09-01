import Foundation

/// Turns a flat list of usage events into the displayable snapshot types. Shared by
/// every platform (macOS app, iOS app, and eventually Windows/Android) so "today's
/// total" or "current block" always means exactly the same computation everywhere —
/// this is what makes multi-device sync actually show the same numbers on every
/// device, not just similar-looking ones.
public enum SnapshotComputer {
    public static func computeSnapshot(
        from events: [UsageEvent],
        manualBlockTokenTarget: Double,
        appearance: GaugeAppearance
    ) -> UsageSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        let todayEvents = events.filter { $0.timestamp >= startOfToday }
        let last7DaysEvents = events.filter { $0.timestamp >= sevenDaysAgo }
        let last7DaysTotalTokens = last7DaysEvents.reduce(0) { $0 + $1.totalTokens }
        let todayTotalTokens = todayEvents.reduce(0) { $0 + $1.totalTokens }

        var breakdownByModel: [String: ModelBreakdown] = [:]
        for event in todayEvents {
            var entry = breakdownByModel[event.model] ?? ModelBreakdown(
                model: event.model, inputTokens: 0, outputTokens: 0,
                cacheCreationTokens: 0, cacheReadTokens: 0, estimatedCostUSD: nil
            )
            entry.inputTokens += event.inputTokens
            entry.outputTokens += event.outputTokens
            entry.cacheCreationTokens += event.cacheCreationTokens
            entry.cacheReadTokens += event.cacheReadTokens
            breakdownByModel[event.model] = entry
        }

        var todayCost: Double = 0
        // Some transcript lines (e.g. internal "<synthetic>" turns) carry a usage block
        // with every field at 0 — harmless to parse, but not worth showing as a line item.
        let breakdown: [ModelBreakdown] = breakdownByModel.values
            .filter { $0.inputTokens + $0.outputTokens + $0.cacheCreationTokens + $0.cacheReadTokens > 0 }
            .map { entry in
                var entry = entry
                let cost = PricingTable.estimatedCostUSD(
                    model: entry.model,
                    inputTokens: entry.inputTokens,
                    outputTokens: entry.outputTokens,
                    cacheCreationTokens: entry.cacheCreationTokens,
                    cacheReadTokens: entry.cacheReadTokens
                )
                entry.estimatedCostUSD = cost
                todayCost += cost ?? 0
                return entry
            }.sorted { $0.model < $1.model }

        let hourlyTokensToday = hourlyBuckets(from: todayEvents.map { ($0.timestamp, $0.totalTokens) }, calendar: calendar)
        let dailyTokensLast7Days = dailyBuckets(from: last7DaysEvents.map { ($0.timestamp, $0.totalTokens) }, calendar: calendar)
        let todayByProject = projectBuckets(from: todayEvents.map { ($0.projectPath, $0.totalTokens) })

        let blocks = SessionBlockCalculator.computeBlocks(from: events)
        let activeBlock = blocks.last.flatMap { now < $0.end ? $0 : nil }
        let pastBlocks = activeBlock == nil ? blocks : blocks.dropLast()
        let historicalMaxBlockTokens = pastBlocks.map(\.totalTokens).max()

        let blockSummary = activeBlock.map {
            SessionBlockSummary(start: $0.start, end: $0.end, totalTokens: $0.totalTokens)
        }

        return UsageSnapshot(
            generatedAt: now,
            todayTotalTokens: todayTotalTokens,
            todayEstimatedCostUSD: todayCost,
            todayModelBreakdown: breakdown,
            todayByProject: todayByProject,
            currentBlock: blockSummary,
            last7DaysTotalTokens: last7DaysTotalTokens,
            hourlyTokensToday: hourlyTokensToday,
            dailyTokensLast7Days: dailyTokensLast7Days,
            historicalMaxBlockTokens: historicalMaxBlockTokens,
            historicalBlockCount: pastBlocks.count,
            manualBlockTokenTarget: manualBlockTokenTarget,
            appearance: appearance
        )
    }

    public static func computeCodexSnapshot(
        from events: [CodexUsageEvent],
        primaryWindow: CodexRateLimitWindow?,
        secondaryWindow: CodexRateLimitWindow?,
        colorHex: String
    ) -> CodexSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        let todayEvents = events.filter { $0.timestamp >= startOfToday }
        let last7DaysEvents = events.filter { $0.timestamp >= sevenDaysAgo }
        let last7DaysTotalTokens = last7DaysEvents.reduce(0) { $0 + $1.totalTokens }
        let todayTotalTokens = todayEvents.reduce(0) { $0 + $1.totalTokens }

        var breakdownByModel: [String: ModelBreakdown] = [:]
        for event in todayEvents {
            var entry = breakdownByModel[event.model] ?? ModelBreakdown(
                model: event.model, inputTokens: 0, outputTokens: 0,
                cacheCreationTokens: 0, cacheReadTokens: 0, estimatedCostUSD: nil
            )
            entry.inputTokens += event.inputTokens
            entry.outputTokens += event.outputTokens
            entry.cacheCreationTokens += event.cachedInputTokens
            breakdownByModel[event.model] = entry
        }
        // Codex is a flat subscription (Plus/Pro/etc.), not pay-per-token — no cost column.
        let breakdown = breakdownByModel.values
            .filter { $0.inputTokens + $0.outputTokens > 0 }
            .sorted { $0.model < $1.model }

        let hourlyTokensToday = hourlyBuckets(from: todayEvents.map { ($0.timestamp, $0.totalTokens) }, calendar: calendar)
        let dailyTokensLast7Days = dailyBuckets(from: last7DaysEvents.map { ($0.timestamp, $0.totalTokens) }, calendar: calendar)
        let todayByProject = projectBuckets(from: todayEvents.map { ($0.projectPath, $0.totalTokens) })

        return CodexSnapshot(
            generatedAt: now,
            todayTotalTokens: todayTotalTokens,
            todayModelBreakdown: breakdown,
            todayByProject: todayByProject,
            hourlyTokensToday: hourlyTokensToday,
            dailyTokensLast7Days: dailyTokensLast7Days,
            last7DaysTotalTokens: last7DaysTotalTokens,
            primaryWindow: primaryWindow,
            secondaryWindow: secondaryWindow,
            colorHex: colorHex
        )
    }

    private static func hourlyBuckets(from events: [(timestamp: Date, tokens: Int)], calendar: Calendar) -> [HourlyUsagePoint] {
        var totalsByHour: [Date: Int] = [:]
        for event in events {
            let hourStart = calendar.date(
                from: calendar.dateComponents([.year, .month, .day, .hour], from: event.timestamp)
            ) ?? event.timestamp
            totalsByHour[hourStart, default: 0] += event.tokens
        }
        return totalsByHour
            .map { HourlyUsagePoint(hourStart: $0.key, tokens: $0.value) }
            .sorted { $0.hourStart < $1.hourStart }
    }

    private static func dailyBuckets(from events: [(timestamp: Date, tokens: Int)], calendar: Calendar) -> [DailyUsagePoint] {
        var totalsByDay: [Date: Int] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            totalsByDay[day, default: 0] += event.tokens
        }
        return totalsByDay
            .map { DailyUsagePoint(day: $0.key, tokens: $0.value) }
            .sorted { $0.day < $1.day }
    }

    private static func projectBuckets(from events: [(projectPath: String, tokens: Int)]) -> [ProjectUsageEntry] {
        var totalsByProject: [String: Int] = [:]
        for event in events {
            totalsByProject[event.projectPath, default: 0] += event.tokens
        }
        return totalsByProject
            .map { ProjectUsageEntry(projectPath: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
    }
}
