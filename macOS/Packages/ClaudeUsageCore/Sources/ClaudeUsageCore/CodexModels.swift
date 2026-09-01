import Foundation

/// One Codex CLI turn, parsed from a `~/.codex/sessions/**/rollout-*.jsonl` transcript.
/// Unlike Claude Code, Codex reports the tokens actually spent on *this* turn directly
/// (`last_token_usage`), no derivation needed.
public struct CodexUsageEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let sessionId: String
    public let projectPath: String

    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    public init(
        timestamp: Date,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        sessionId: String,
        projectPath: String
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.sessionId = sessionId
        self.projectPath = projectPath
    }

    // Custom decoding so `projectPath` (added after this app already had events synced to
    // Firestore) defaults instead of failing to decode entirely — otherwise every
    // already-uploaded remote event silently vanishes from paired devices (the
    // `try?`-based decode call sites treat a decode failure as "skip this event") until
    // each device's per-syncId upload watermark naturally moves past it, which for
    // historical events may be never.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        model = try container.decode(String.self, forKey: .model)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        cachedInputTokens = try container.decode(Int.self, forKey: .cachedInputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        reasoningOutputTokens = try container.decode(Int.self, forKey: .reasoningOutputTokens)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? "unknown"
    }
}

/// A rate-limit window as reported directly by OpenAI (no estimation involved), e.g.
/// primary = rolling 5h window, secondary = rolling 7-day window.
public struct CodexRateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date
    public let planType: String?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date, planType: String?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.planType = planType
    }

    public var fraction: Double {
        min(1, max(0, usedPercent / 100))
    }
}

/// The Codex-side equivalent of `UsageSnapshot`. Kept as a separate type (rather than
/// unifying with Claude's) because the underlying data is fundamentally different in
/// kind: Claude's block/limit numbers are heuristic estimates, Codex's are official
/// values straight from OpenAI's rate-limit headers.
public struct CodexSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let todayTotalTokens: Int
    public let todayModelBreakdown: [ModelBreakdown]
    public let todayByProject: [ProjectUsageEntry]
    public let hourlyTokensToday: [HourlyUsagePoint]
    public let dailyTokensLast7Days: [DailyUsagePoint]
    public let last7DaysTotalTokens: Int
    /// The shorter-window limit (Claude Code's primary reference is a ~5h window; Codex
    /// reports whichever window OpenAI configures, observed as ~5h in practice).
    public let primaryWindow: CodexRateLimitWindow?
    /// A longer-window limit (observed as ~7 days), shown as supplementary context.
    public let secondaryWindow: CodexRateLimitWindow?
    public let colorHex: String

    public init(
        generatedAt: Date,
        todayTotalTokens: Int,
        todayModelBreakdown: [ModelBreakdown],
        todayByProject: [ProjectUsageEntry],
        hourlyTokensToday: [HourlyUsagePoint],
        dailyTokensLast7Days: [DailyUsagePoint],
        last7DaysTotalTokens: Int,
        primaryWindow: CodexRateLimitWindow?,
        secondaryWindow: CodexRateLimitWindow?,
        colorHex: String
    ) {
        self.generatedAt = generatedAt
        self.todayTotalTokens = todayTotalTokens
        self.todayModelBreakdown = todayModelBreakdown
        self.todayByProject = todayByProject
        self.hourlyTokensToday = hourlyTokensToday
        self.dailyTokensLast7Days = dailyTokensLast7Days
        self.last7DaysTotalTokens = last7DaysTotalTokens
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.colorHex = colorHex
    }

    public static let empty = CodexSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        todayTotalTokens: 0,
        todayModelBreakdown: [],
        todayByProject: [],
        hourlyTokensToday: [],
        dailyTokensLast7Days: [],
        last7DaysTotalTokens: 0,
        primaryWindow: nil,
        secondaryWindow: nil,
        colorHex: "#22C55E"
    )
}
