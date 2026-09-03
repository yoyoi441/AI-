import Foundation

public enum OllamaUsageSource: String, Codable, Equatable, Sendable {
    case local
    case cloud
}

/// One completed Ollama API response captured by Token Mihariban's opt-in local proxy.
/// Prompt/response text is intentionally never persisted.
public struct OllamaUsageEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalDurationNanoseconds: Int64
    public let source: OllamaUsageSource
    public let requestId: String

    public var totalTokens: Int { inputTokens + outputTokens }

    public init(
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        totalDurationNanoseconds: Int64,
        source: OllamaUsageSource,
        requestId: String
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalDurationNanoseconds = totalDurationNanoseconds
        self.source = source
        self.requestId = requestId
    }
}

/// Kept model-by-model even though v0.4 presents a single aggregate Ollama ring. This
/// lets a later setting expose selected models without migrating the stored history.
public struct OllamaModelBreakdown: Codable, Equatable, Sendable, Identifiable {
    public var id: String { model }
    public let model: String
    public var localInputTokens: Int
    public var localOutputTokens: Int
    public var cloudInputTokens: Int
    public var cloudOutputTokens: Int
    public var cloudEstimatedCostUSD: Double?

    public var totalTokens: Int {
        localInputTokens + localOutputTokens + cloudInputTokens + cloudOutputTokens
    }
}

public struct OllamaSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let todayTotalTokens: Int
    public let todayLocalTokens: Int
    public let todayCloudTokens: Int
    public let todayCloudEstimatedCostUSD: Double
    public let todayModelBreakdown: [OllamaModelBreakdown]
    public let hourlyTokensToday: [HourlyUsagePoint]
    public let dailyTokensLast7Days: [DailyUsagePoint]
    public let last7DaysTotalTokens: Int
    public let dailyTokenTarget: Double
    public let colorHex: String

    public var targetFraction: Double? {
        guard dailyTokenTarget > 0 else { return nil }
        return min(1, max(0, Double(todayTotalTokens) / dailyTokenTarget))
    }

    public var hasUnpricedCloudModelToday: Bool {
        todayModelBreakdown.contains {
            $0.cloudInputTokens + $0.cloudOutputTokens > 0 && $0.cloudEstimatedCostUSD == nil
        }
    }

    public static let empty = OllamaSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        todayTotalTokens: 0,
        todayLocalTokens: 0,
        todayCloudTokens: 0,
        todayCloudEstimatedCostUSD: 0,
        todayModelBreakdown: [],
        hourlyTokensToday: [],
        dailyTokensLast7Days: [],
        last7DaysTotalTokens: 0,
        dailyTokenTarget: 0,
        colorHex: "#F97316"
    )
}

public enum OllamaUsageComputer {
    public static func estimatedCloudCostUSD(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let pricing = OllamaCloudPricing.lookup(model: model) else { return nil }
        return Double(inputTokens) / 1_000_000 * pricing.input
            + Double(outputTokens) / 1_000_000 * pricing.output
    }

    public static func compute(
        events: [OllamaUsageEvent],
        dailyTokenTarget: Double,
        colorHex: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> OllamaSnapshot {
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let today = events.filter { $0.timestamp >= startOfToday && $0.timestamp <= now }
        let recent = events.filter { $0.timestamp >= sevenDaysAgo && $0.timestamp <= now }

        var byModel: [String: OllamaModelBreakdown] = [:]
        for event in today {
            var row = byModel[event.model] ?? OllamaModelBreakdown(
                model: event.model,
                localInputTokens: 0,
                localOutputTokens: 0,
                cloudInputTokens: 0,
                cloudOutputTokens: 0,
                cloudEstimatedCostUSD: nil
            )
            if event.source == .cloud {
                row.cloudInputTokens += event.inputTokens
                row.cloudOutputTokens += event.outputTokens
            } else {
                row.localInputTokens += event.inputTokens
                row.localOutputTokens += event.outputTokens
            }
            byModel[event.model] = row
        }

        var cost = 0.0
        let breakdown = byModel.values.map { value -> OllamaModelBreakdown in
            var row = value
            if row.cloudInputTokens + row.cloudOutputTokens > 0,
               let estimated = estimatedCloudCostUSD(
                    model: row.model,
                    inputTokens: row.cloudInputTokens,
                    outputTokens: row.cloudOutputTokens
               ) {
                row.cloudEstimatedCostUSD = estimated
                cost += estimated
            }
            return row
        }.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }

        func hourly(_ source: [OllamaUsageEvent]) -> [HourlyUsagePoint] {
            let grouped = Dictionary(grouping: source) {
                calendar.dateInterval(of: .hour, for: $0.timestamp)?.start ?? $0.timestamp
            }
            return grouped.map { HourlyUsagePoint(hourStart: $0.key, tokens: $0.value.reduce(0) { $0 + $1.totalTokens }) }
                .sorted { $0.hourStart < $1.hourStart }
        }

        func daily(_ source: [OllamaUsageEvent]) -> [DailyUsagePoint] {
            let grouped = Dictionary(grouping: source) { calendar.startOfDay(for: $0.timestamp) }
            return grouped.map { DailyUsagePoint(day: $0.key, tokens: $0.value.reduce(0) { $0 + $1.totalTokens }) }
                .sorted { $0.day < $1.day }
        }

        let localTokens = today.filter { $0.source == .local }.reduce(0) { $0 + $1.totalTokens }
        let cloudTokens = today.filter { $0.source == .cloud }.reduce(0) { $0 + $1.totalTokens }
        return OllamaSnapshot(
            generatedAt: now,
            todayTotalTokens: localTokens + cloudTokens,
            todayLocalTokens: localTokens,
            todayCloudTokens: cloudTokens,
            todayCloudEstimatedCostUSD: cost,
            todayModelBreakdown: breakdown,
            hourlyTokensToday: hourly(today),
            dailyTokensLast7Days: daily(recent),
            last7DaysTotalTokens: recent.reduce(0) { $0 + $1.totalTokens },
            dailyTokenTarget: dailyTokenTarget,
            colorHex: colorHex
        )
    }
}

public enum OllamaUsageResponseParser {
    /// Reads the final object in either a JSON response or an NDJSON/SSE stream.
    public static func parse(
        _ data: Data,
        requestedModel: String?,
        forceCloud: Bool,
        requestId: String = UUID().uuidString,
        fallbackDate: Date = Date()
    ) -> OllamaUsageEvent? {
        var candidates: [Any] = []
        if let object = try? JSONSerialization.jsonObject(with: data) {
            candidates.append(object)
        } else if let text = String(data: data, encoding: .utf8) {
            for rawLine in text.split(whereSeparator: \.isNewline).reversed() {
                var line = String(rawLine).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("data:") { line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                guard line != "[DONE]", let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) else { continue }
                candidates.append(object)
            }
        }

        guard let dictionary = candidates.compactMap({ $0 as? [String: Any] }).first(where: {
            int64($0["prompt_eval_count"]) != nil || int64($0["eval_count"]) != nil
        }) else { return nil }

        let input = Int(int64(dictionary["prompt_eval_count"]) ?? 0)
        let output = Int(int64(dictionary["eval_count"]) ?? 0)
        guard input > 0 || output > 0 else { return nil }
        let model = (dictionary["model"] as? String) ?? requestedModel ?? "unknown"
        let remoteHost = dictionary["remote_host"] as? String
        let sourceText = dictionary["source"] as? String
        let isCloud = forceCloud || model.lowercased().hasSuffix(":cloud")
            || !(remoteHost ?? "").isEmpty || sourceText?.lowercased() == "cloud"
        let date = (dictionary["created_at"] as? String).flatMap(parseDate) ?? fallbackDate
        return OllamaUsageEvent(
            timestamp: date,
            model: model,
            inputTokens: input,
            outputTokens: output,
            totalDurationNanoseconds: int64(dictionary["total_duration"]) ?? 0,
            source: isCloud ? .cloud : .local,
            requestId: requestId
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private enum OllamaCloudPricing {
    struct Price { let input: Double; let output: Double }

    // USD per million tokens. Kept deliberately small and easy to update as Ollama's
    // public pricing changes; unknown models remain explicitly "unpriced".
    static let models: [String: Price] = [
        "deepseek-v4-flash": Price(input: 0.44, output: 1.32),
        "deepseek-v4-pro": Price(input: 1.32, output: 3.96),
        "gemma4": Price(input: 0.14, output: 0.40),
        "glm-5.3": Price(input: 1.40, output: 4.40),
        "glm-5.3-flash": Price(input: 0.15, output: 0.50),
        "glm-5.2": Price(input: 1.40, output: 4.40),
        "glm-5.1": Price(input: 1.00, output: 3.20),
        "gpt-oss:120b": Price(input: 0.15, output: 0.60),
        "gpt-oss:20b": Price(input: 0.07, output: 0.30),
        "kimi-k3": Price(input: 3.00, output: 15.00),
        "kimi-k2.7-code": Price(input: 0.95, output: 4.00),
        "kimi-k2.6": Price(input: 0.95, output: 4.00),
        "minimax-m3": Price(input: 0.60, output: 2.40),
        "minimax-m2.7": Price(input: 0.30, output: 1.20),
        "mistral-large-3": Price(input: 0.50, output: 1.50),
        "nemotron-3-nano": Price(input: 0.06, output: 0.24),
        "nemotron-3-super": Price(input: 0.015, output: 0.60),
        "nemotron-3-ultra": Price(input: 0.10, output: 3.00),
        "qwen3.5:397b": Price(input: 0.60, output: 3.60)
    ]

    static func lookup(model: String) -> Price? {
        var key = model.lowercased()
        if key.hasSuffix(":cloud") { key.removeLast(6) }
        if key.hasSuffix("-cloud") { key.removeLast(6) }
        return models[key]
    }
}
