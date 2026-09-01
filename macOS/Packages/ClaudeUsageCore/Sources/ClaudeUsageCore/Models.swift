import Foundation

/// One Claude Code API call, parsed from a `~/.claude/projects/**/*.jsonl` transcript line.
public struct UsageEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let sessionId: String
    public let projectPath: String

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public init(
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        sessionId: String,
        projectPath: String
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.sessionId = sessionId
        self.projectPath = projectPath
    }
}

/// A contiguous 5-hour usage window, estimated from event timestamps.
///
/// Anthropic does not publish the exact algorithm behind the Pro/Max "5-hour limit"
/// window, so this is a heuristic approximation (the same approach community tools
/// such as ccusage use): a block starts at the hour of the first event in it and
/// spans 5 hours, or ends early if there's a 5+ hour gap with no activity.
public struct SessionBlock: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let events: [UsageEvent]

    public init(start: Date, end: Date, events: [UsageEvent]) {
        self.start = start
        self.end = end
        self.events = events
    }

    public var totalTokens: Int {
        events.reduce(0) { $0 + $1.totalTokens }
    }
}

/// Per-model token totals for a given period (e.g. today).
public struct ModelBreakdown: Codable, Equatable, Sendable, Identifiable {
    public var id: String { model }
    public let model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    /// nil when the model isn't in `PricingTable` — excluded from cost totals rather than guessed.
    public var estimatedCostUSD: Double?

    public init(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double?
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

/// One hour's token total, for today's usage bar chart.
public struct HourlyUsagePoint: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { hourStart }
    public let hourStart: Date
    public let tokens: Int

    public init(hourStart: Date, tokens: Int) {
        self.hourStart = hourStart
        self.tokens = tokens
    }
}

/// Today's token total for one project directory (`UsageEvent.projectPath` /
/// `CodexUsageEvent.projectPath`, i.e. the working directory Claude Code/Codex ran in).
public struct ProjectUsageEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { projectPath }
    public let projectPath: String
    public let tokens: Int

    /// The project directory's own name (last path component) rather than the full path,
    /// which is normally too long to fit in the UI and reveals more of the filesystem
    /// layout than necessary — e.g. "/Users/x/dev/my-app" displays as "my-app".
    public var displayName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public init(projectPath: String, tokens: Int) {
        self.projectPath = projectPath
        self.tokens = tokens
    }
}

/// One day's token total, for the last-7-days bar chart.
public struct DailyUsagePoint: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { day }
    public let day: Date
    public let tokens: Int

    public init(day: Date, tokens: Int) {
        self.day = day
        self.tokens = tokens
    }
}

/// Lightweight, Codable summary of the active block, shared with the widget via SnapshotStore.
public struct SessionBlockSummary: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let totalTokens: Int

    public init(start: Date, end: Date, totalTokens: Int) {
        self.start = start
        self.end = end
        self.totalTokens = totalTokens
    }
}

/// Whether gauges render as a horizontal capacity bar or a circular ring. Chosen once
/// in Settings, applied identically in the menu bar dropdown and the widget.
public enum GaugeDisplayStyle: String, Codable, Equatable, Sendable, CaseIterable {
    case bar
    case ring

    public func label(_ lang: AppLanguage) -> String {
        switch self {
        case .bar: return L.string("styleBar", lang: lang)
        case .ring: return L.string("styleRing", lang: lang)
        }
    }
}

/// What the cramped menu bar status icon's ring/bar fraction represents — there isn't
/// room there to label it, so which metric it is has to be a deliberate user choice
/// instead of a guess. Chosen once in Settings, applied to every provider's icon.
public enum GaugeMetric: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case timeRemaining
    case tokenUsage

    public var id: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch self {
        case .timeRemaining: return L.string("menuBarMetricTime", lang: lang)
        case .tokenUsage: return L.string("menuBarMetricTokenUsage", lang: lang)
        }
    }
}

/// Which provider the small (single-gauge) iOS home screen widget shows. Medium/Large
/// widgets have room for both Claude and Codex side by side already, so this only
/// matters for the small size.
public enum WidgetProvider: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// User-chosen gauge/chart styling, carried inside `UsageSnapshot` so the widget
/// extension (a separate sandboxed process) picks it up via the same plain-file
/// SnapshotStore mechanism as everything else — no App Group UserDefaults suite
/// involved, since that combination is unreliable from a non-sandboxed host app.
public struct GaugeAppearance: Codable, Equatable, Sendable {
    public let colorHex: String
    public let useGradient: Bool
    public let style: GaugeDisplayStyle

    public init(colorHex: String, useGradient: Bool, style: GaugeDisplayStyle) {
        self.colorHex = colorHex
        self.useGradient = useGradient
        self.style = style
    }

    public static let `default` = GaugeAppearance(colorHex: "#3B82F6", useGradient: true, style: .ring)
}

/// The full snapshot the main app computes and the widget extension displays.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let todayTotalTokens: Int
    public let todayEstimatedCostUSD: Double
    public let todayModelBreakdown: [ModelBreakdown]
    /// Today's tokens grouped by project directory, sorted descending. Empty entries
    /// (a project with 0 tokens today) are never included.
    public let todayByProject: [ProjectUsageEntry]
    public let currentBlock: SessionBlockSummary?
    /// Supplementary rolling total. Not shown as "% of limit" since the weekly cap isn't public.
    public let last7DaysTotalTokens: Int
    public let hourlyTokensToday: [HourlyUsagePoint]
    public let dailyTokensLast7Days: [DailyUsagePoint]
    /// Largest completed block on record (excludes the still-open current block, if any).
    /// Used as the default "full" reference for the token gauge when the user hasn't set
    /// a manual target — a personal-history estimate, not an official limit.
    public let historicalMaxBlockTokens: Int?
    /// How many completed blocks `historicalMaxBlockTokens` is drawn from — with very few,
    /// the "自己ベースの目安" reference is really just whatever one block happened to look
    /// like, not a stable personal baseline yet. Lets the UI flag that explicitly instead
    /// of presenting a single data point with the same confidence as an established one.
    public let historicalBlockCount: Int
    /// User-entered token target from Settings; 0 means "unset, use historicalMaxBlockTokens".
    public let manualBlockTokenTarget: Double
    public let appearance: GaugeAppearance

    public var referenceTokens: Int? {
        manualBlockTokenTarget > 0 ? Int(manualBlockTokenTarget) : historicalMaxBlockTokens
    }

    /// True when the gauge's "full" reference is a self-based estimate (no manual target
    /// set) drawn from fewer than 3 completed blocks — too little history to trust as a
    /// stable personal baseline yet.
    public var referenceIsLowConfidence: Bool {
        manualBlockTokenTarget <= 0 && historicalBlockCount < 3
    }

    /// True when today's usage includes a model `PricingTable` doesn't have pricing for
    /// — `todayEstimatedCostUSD` silently excludes that model's tokens rather than
    /// guessing at $0, so without this flag the total would look complete when it isn't.
    public var hasUnpricedModelToday: Bool {
        todayModelBreakdown.contains { $0.estimatedCostUSD == nil }
    }

    public init(
        generatedAt: Date,
        todayTotalTokens: Int,
        todayEstimatedCostUSD: Double,
        todayModelBreakdown: [ModelBreakdown],
        todayByProject: [ProjectUsageEntry],
        currentBlock: SessionBlockSummary?,
        last7DaysTotalTokens: Int,
        hourlyTokensToday: [HourlyUsagePoint],
        dailyTokensLast7Days: [DailyUsagePoint],
        historicalMaxBlockTokens: Int?,
        historicalBlockCount: Int,
        manualBlockTokenTarget: Double,
        appearance: GaugeAppearance
    ) {
        self.generatedAt = generatedAt
        self.todayTotalTokens = todayTotalTokens
        self.todayEstimatedCostUSD = todayEstimatedCostUSD
        self.todayModelBreakdown = todayModelBreakdown
        self.todayByProject = todayByProject
        self.currentBlock = currentBlock
        self.last7DaysTotalTokens = last7DaysTotalTokens
        self.hourlyTokensToday = hourlyTokensToday
        self.dailyTokensLast7Days = dailyTokensLast7Days
        self.historicalMaxBlockTokens = historicalMaxBlockTokens
        self.historicalBlockCount = historicalBlockCount
        self.manualBlockTokenTarget = manualBlockTokenTarget
        self.appearance = appearance
    }

    public static let empty = UsageSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        todayTotalTokens: 0,
        todayEstimatedCostUSD: 0,
        todayModelBreakdown: [],
        todayByProject: [],
        currentBlock: nil,
        last7DaysTotalTokens: 0,
        hourlyTokensToday: [],
        dailyTokensLast7Days: [],
        historicalMaxBlockTokens: nil,
        historicalBlockCount: 0,
        manualBlockTokenTarget: 0,
        appearance: .default
    )
}
