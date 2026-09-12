import Foundation

/// AI clients/runtimes whose own durable usage records can be read without storing
/// prompts or responses. Multiple tools intentionally share one snapshot/ring so the
/// menu bar does not grow without bound as integrations are added.
public enum AIToolKind: String, Codable, Equatable, Sendable, CaseIterable {
    case geminiCLI = "gemini-cli"
    case openCode = "opencode"

    public var displayName: String {
        switch self {
        case .geminiCLI: return "Gemini CLI"
        case .openCode: return "OpenCode"
        }
    }
}

public struct AIToolUsageEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let tool: AIToolKind
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let reasoningTokens: Int
    /// Provider-reported total. This is kept explicitly because Gemini's total also
    /// includes tool-use tokens and cannot always be reconstructed from the breakdown.
    public let totalTokens: Int
    public let eventId: String
    public let sessionId: String
    public let projectPath: String

    public init(
        timestamp: Date,
        tool: AIToolKind,
        provider: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int,
        reasoningTokens: Int,
        totalTokens: Int,
        eventId: String,
        sessionId: String,
        projectPath: String
    ) {
        self.timestamp = timestamp
        self.tool = tool
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.eventId = eventId
        self.sessionId = sessionId
        self.projectPath = projectPath
    }
}

public struct AIToolBreakdown: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(tool.rawValue)|\(provider)|\(model)" }
    public let tool: AIToolKind
    public let provider: String
    public let model: String
    public let tokens: Int

    public var displayName: String {
        let providerPrefix = provider.isEmpty || provider == "google" ? "" : "\(provider) / "
        return "\(tool.displayName) · \(providerPrefix)\(model)"
    }
}

public struct AIToolSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let todayTotalTokens: Int
    public let todayBreakdown: [AIToolBreakdown]
    public let hourlyTokensToday: [HourlyUsagePoint]
    public let dailyTokensLast7Days: [DailyUsagePoint]
    public let last7DaysTotalTokens: Int
    public let dailyTokenTarget: Double
    public let colorHex: String

    public var targetFraction: Double? {
        guard dailyTokenTarget > 0 else { return nil }
        return min(1, max(0, Double(todayTotalTokens) / dailyTokenTarget))
    }

    public static let empty = AIToolSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        todayTotalTokens: 0,
        todayBreakdown: [],
        hourlyTokensToday: [],
        dailyTokensLast7Days: [],
        last7DaysTotalTokens: 0,
        dailyTokenTarget: 0,
        colorHex: "#8B5CF6"
    )
}

public enum AIToolUsageComputer {
    public static func compute(
        events: [AIToolUsageEvent],
        dailyTokenTarget: Double,
        colorHex: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AIToolSnapshot {
        // Sync and legacy files can surface the same durable message more than once.
        // Latest wins, but its provider total is counted exactly once.
        let deduplicated = Dictionary(events.map { ($0.eventId, $0) }, uniquingKeysWith: { _, newest in newest }).values
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let today = deduplicated.filter { $0.timestamp >= startOfToday && $0.timestamp <= now }
        let recent = deduplicated.filter { $0.timestamp >= sevenDaysAgo && $0.timestamp <= now }

        let grouped = Dictionary(grouping: today) { "\($0.tool.rawValue)|\($0.provider)|\($0.model)" }
        let breakdown = grouped.values.compactMap { values -> AIToolBreakdown? in
            guard let first = values.first else { return nil }
            return AIToolBreakdown(
                tool: first.tool,
                provider: first.provider,
                model: first.model,
                tokens: values.reduce(0) { $0 + $1.totalTokens }
            )
        }.sorted { $0.tokens > $1.tokens }

        func hourly(_ values: some Sequence<AIToolUsageEvent>) -> [HourlyUsagePoint] {
            let grouped = Dictionary(grouping: Array(values)) {
                calendar.dateInterval(of: .hour, for: $0.timestamp)?.start ?? $0.timestamp
            }
            return grouped.map { HourlyUsagePoint(hourStart: $0.key, tokens: $0.value.reduce(0) { $0 + $1.totalTokens }) }
                .sorted { $0.hourStart < $1.hourStart }
        }

        func daily(_ values: some Sequence<AIToolUsageEvent>) -> [DailyUsagePoint] {
            let grouped = Dictionary(grouping: Array(values)) { calendar.startOfDay(for: $0.timestamp) }
            return grouped.map { DailyUsagePoint(day: $0.key, tokens: $0.value.reduce(0) { $0 + $1.totalTokens }) }
                .sorted { $0.day < $1.day }
        }

        return AIToolSnapshot(
            generatedAt: now,
            todayTotalTokens: today.reduce(0) { $0 + $1.totalTokens },
            todayBreakdown: breakdown,
            hourlyTokensToday: hourly(today),
            dailyTokensLast7Days: daily(recent),
            last7DaysTotalTokens: recent.reduce(0) { $0 + $1.totalTokens },
            dailyTokenTarget: dailyTokenTarget,
            colorHex: colorHex
        )
    }
}

