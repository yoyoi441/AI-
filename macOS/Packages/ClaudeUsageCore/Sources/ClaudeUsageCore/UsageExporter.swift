import Foundation

/// One Claude Code, Codex, or Ollama call, flattened into a single exportable row.
/// Kept as raw per-event rows (not pre-aggregated by day/model) so a spreadsheet or
/// script on the receiving end can group/pivot however the user actually needs —
/// aggregating here would throw away information there's no way to recover afterward.
public struct UsageExportRow: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let provider: String
    public let model: String
    public let projectPath: String
    public let sessionId: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let totalTokens: Int
    /// nil for Codex, local Ollama, and models without a known public token rate — never
    /// a silent $0, matching how the in-app cost total works.
    public let estimatedCostUSD: Double?

    public init(
        timestamp: Date,
        provider: String,
        model: String,
        projectPath: String,
        sessionId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        totalTokens: Int,
        estimatedCostUSD: Double?
    ) {
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.projectPath = projectPath
        self.sessionId = sessionId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

/// Builds an export of raw usage events for a date range, for expense reports or
/// personal analysis outside the app. Shared by every platform so "what counts as
/// today's data" is defined identically to the in-app totals.
public enum UsageExporter {
    public static func rows(
        claudeEvents: [UsageEvent],
        codexEvents: [CodexUsageEvent],
        ollamaEvents: [OllamaUsageEvent],
        from start: Date,
        to end: Date
    ) -> [UsageExportRow] {
        let claudeRows = claudeEvents
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .map { event -> UsageExportRow in
                UsageExportRow(
                    timestamp: event.timestamp,
                    provider: "Claude Code",
                    model: event.model,
                    projectPath: event.projectPath,
                    sessionId: event.sessionId,
                    inputTokens: event.inputTokens,
                    outputTokens: event.outputTokens,
                    cacheCreationTokens: event.cacheCreationTokens,
                    cacheReadTokens: event.cacheReadTokens,
                    totalTokens: event.totalTokens,
                    estimatedCostUSD: PricingTable.estimatedCostUSD(
                        model: event.model,
                        inputTokens: event.inputTokens,
                        outputTokens: event.outputTokens,
                        cacheCreationTokens: event.cacheCreationTokens,
                        cacheReadTokens: event.cacheReadTokens
                    )
                )
            }

        let codexRows = codexEvents
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .map { event -> UsageExportRow in
                UsageExportRow(
                    timestamp: event.timestamp,
                    provider: "Codex",
                    model: event.model,
                    projectPath: event.projectPath,
                    sessionId: event.sessionId,
                    inputTokens: event.inputTokens,
                    outputTokens: event.outputTokens,
                    cacheCreationTokens: event.cachedInputTokens,
                    cacheReadTokens: 0,
                    totalTokens: event.totalTokens,
                    estimatedCostUSD: nil
                )
            }

        let ollamaRows = ollamaEvents
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .map { event -> UsageExportRow in
                UsageExportRow(
                    timestamp: event.timestamp,
                    provider: event.source == .cloud ? "Ollama Cloud" : "Ollama Local",
                    model: event.model,
                    projectPath: "",
                    sessionId: event.requestId,
                    inputTokens: event.inputTokens,
                    outputTokens: event.outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    totalTokens: event.totalTokens,
                    estimatedCostUSD: event.source == .cloud
                        ? OllamaUsageComputer.estimatedCloudCostUSD(model: event.model, inputTokens: event.inputTokens, outputTokens: event.outputTokens)
                        : nil
                )
            }

        return (claudeRows + codexRows + ollamaRows).sorted { $0.timestamp < $1.timestamp }
    }

    // Configured once and never mutated afterward, so shared read-only access across
    // threads is safe despite ISO8601DateFormatter not being Sendable (same pattern as
    // CodexJSONLParser's formatters).
    nonisolated(unsafe) private static let csvTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func csv(rows: [UsageExportRow]) -> String {
        var lines = ["timestamp,provider,model,project,sessionId,inputTokens,outputTokens,cacheCreationTokens,cacheReadTokens,totalTokens,estimatedCostUSD"]
        for row in rows {
            let cost = row.estimatedCostUSD.map { String(format: "%.4f", $0) } ?? ""
            let fields = [
                csvTimestampFormatter.string(from: row.timestamp),
                row.provider,
                row.model,
                row.projectPath,
                row.sessionId,
                String(row.inputTokens),
                String(row.outputTokens),
                String(row.cacheCreationTokens),
                String(row.cacheReadTokens),
                String(row.totalTokens),
                cost
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public static func json(rows: [UsageExportRow]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(rows)
    }
}
