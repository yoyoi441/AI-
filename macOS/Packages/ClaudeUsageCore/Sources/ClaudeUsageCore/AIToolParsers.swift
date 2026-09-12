import Foundation

public enum GeminiSessionParser {
    public static func parse(_ data: Data, fallbackSessionId: String = "unknown") -> [AIToolUsageEvent] {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseLegacy(root, fallbackSessionId: fallbackSessionId)
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var sessionId = fallbackSessionId
        var projectPath = "unknown"
        var events: [AIToolUsageEvent] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            sessionId = string(object["sessionId"]) ?? sessionId
            projectPath = firstDirectory(object) ?? projectPath
            if let set = object["$set"] as? [String: Any] {
                sessionId = string(set["sessionId"]) ?? sessionId
                projectPath = firstDirectory(set) ?? projectPath
                if let messages = set["messages"] as? [[String: Any]] {
                    events.append(contentsOf: messages.compactMap { event($0, sessionId: sessionId, projectPath: projectPath) })
                }
            }
            if let parsed = event(object, sessionId: sessionId, projectPath: projectPath) { events.append(parsed) }
        }
        return deduplicate(events)
    }

    private static func parseLegacy(_ root: [String: Any], fallbackSessionId: String) -> [AIToolUsageEvent] {
        let sessionId = string(root["sessionId"]) ?? fallbackSessionId
        let projectPath = firstDirectory(root) ?? "unknown"
        let messages = root["messages"] as? [[String: Any]] ?? []
        return deduplicate(messages.compactMap { event($0, sessionId: sessionId, projectPath: projectPath) })
    }

    private static func event(_ value: [String: Any], sessionId: String, projectPath: String) -> AIToolUsageEvent? {
        guard string(value["type"]) == "gemini",
              let tokens = value["tokens"] as? [String: Any],
              let timestampText = string(value["timestamp"]),
              let timestamp = parseDate(timestampText) else { return nil }
        let input = integer(tokens["input"])
        let output = integer(tokens["output"])
        let cached = integer(tokens["cached"])
        let reasoning = integer(tokens["thoughts"])
        let total = integer(tokens["total"])
        guard total > 0 || input > 0 || output > 0 else { return nil }
        let messageId = string(value["id"]) ?? "\(timestamp.timeIntervalSince1970)"
        return AIToolUsageEvent(
            timestamp: timestamp,
            tool: .geminiCLI,
            provider: "google",
            model: string(value["model"]) ?? "unknown",
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: reasoning,
            totalTokens: total > 0 ? total : input + output + reasoning,
            eventId: "gemini:\(sessionId):\(messageId)",
            sessionId: sessionId,
            projectPath: projectPath
        )
    }

    private static func firstDirectory(_ value: [String: Any]) -> String? {
        (value["directories"] as? [String])?.first
    }

    private static func deduplicate(_ events: [AIToolUsageEvent]) -> [AIToolUsageEvent] {
        Array(Dictionary(events.map { ($0.eventId, $0) }, uniquingKeysWith: { _, latest in latest }).values)
    }
}

public enum OpenCodeMessageParser {
    /// Parses the JSON stored in OpenCode's `message.data` SQLite column. User messages
    /// and response text are ignored; only the assistant usage envelope is retained.
    public static func parseMessageData(_ data: Data) -> AIToolUsageEvent? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              string(value["role"]) == "assistant",
              let tokens = value["tokens"] as? [String: Any],
              let time = value["time"] as? [String: Any] else { return nil }
        let created = double(time["created"])
        guard created > 0 else { return nil }
        let input = integer(tokens["input"])
        let output = integer(tokens["output"])
        let reasoning = integer(tokens["reasoning"])
        let cache = tokens["cache"] as? [String: Any]
        let cached = integer(cache?["read"])
        let explicitTotal = integer(tokens["total"])
        let total = explicitTotal > 0 ? explicitTotal : input + output + reasoning
        guard total > 0 else { return nil }
        let messageId = string(value["id"]) ?? "\(created)"
        let sessionId = string(value["sessionID"]) ?? "unknown"
        let path = value["path"] as? [String: Any]
        return AIToolUsageEvent(
            timestamp: Date(timeIntervalSince1970: created / 1000),
            tool: .openCode,
            provider: string(value["providerID"]) ?? "unknown",
            model: string(value["modelID"]) ?? "unknown",
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: reasoning,
            totalTokens: total,
            eventId: "opencode:\(messageId)",
            sessionId: sessionId,
            projectPath: string(path?["cwd"]) ?? "unknown"
        )
    }
}

private func string(_ value: Any?) -> String? { value as? String }
private func integer(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) ?? 0 }
    return 0
}
private func double(_ value: Any?) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text) ?? 0 }
    return 0
}
private func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
