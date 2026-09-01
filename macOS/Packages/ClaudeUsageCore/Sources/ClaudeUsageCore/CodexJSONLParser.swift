import Foundation

/// Parses Codex CLI's local session transcripts (`~/.codex/sessions/**/rollout-*.jsonl`).
///
/// Each line is a standalone JSON event. The model in use is announced on `turn_context`
/// lines and applies to `token_count` events that follow, so parsing is stateful within
/// a single call (unlike `JSONLParser`, where every line is self-contained). If a batch
/// of newly-appended lines happens to start mid-session without a fresh `turn_context`,
/// the model falls back to "unknown" for that batch — a rare edge case in practice,
/// since a full history parse (offset 0) always sees every `turn_context` first.
public enum CodexJSONLParser {
    private struct RawLine: Decodable {
        struct Payload: Decodable {
            struct TokenUsage: Decodable {
                let input_tokens: Int?
                let cached_input_tokens: Int?
                let output_tokens: Int?
                let reasoning_output_tokens: Int?
            }
            struct Info: Decodable {
                let last_token_usage: TokenUsage?
            }
            struct RateLimitWindow: Decodable {
                let used_percent: Double?
                let window_minutes: Int?
                let resets_at: Double?
            }
            struct RateLimits: Decodable {
                let primary: RateLimitWindow?
                let secondary: RateLimitWindow?
                let plan_type: String?
            }

            let type: String?
            let model: String?
            let info: Info?
            let rate_limits: RateLimits?
            let cwd: String?
        }

        let type: String?
        let timestamp: String?
        let payload: Payload?
    }

    public struct ParseResult {
        public let events: [CodexUsageEvent]
        public let latestPrimaryWindow: CodexRateLimitWindow?
        public let latestSecondaryWindow: CodexRateLimitWindow?
        /// When `latestPrimaryWindow`/`latestSecondaryWindow` were reported (the
        /// `token_count` event's own timestamp, not `resets_at`). Files aren't
        /// necessarily visited in chronological order, so callers comparing results
        /// across multiple files need this to know which reading is actually newest.
        public let latestWindowEventTimestamp: Date?
        public let newOffset: UInt64
    }

    // Configured once and never mutated afterward, so shared read-only access across
    // threads is safe despite ISO8601DateFormatter not being Sendable.
    nonisolated(unsafe) private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseDate(_ string: String) -> Date? {
        isoFormatterWithFractionalSeconds.date(from: string) ?? isoFormatter.date(from: string)
    }

    private static func parseWindow(_ raw: RawLine.Payload.RateLimitWindow?, planType: String?) -> CodexRateLimitWindow? {
        guard let raw, let usedPercent = raw.used_percent, let windowMinutes = raw.window_minutes, let resetsAt = raw.resets_at else {
            return nil
        }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: Date(timeIntervalSince1970: resetsAt),
            planType: planType
        )
    }

    public static func parseFile(at url: URL, sessionId: String, fromByteOffset byteOffset: UInt64 = 0) throws -> ParseResult {
        var events: [CodexUsageEvent] = []
        var currentModel = "unknown"
        // Set once from the file's `session_meta` line (always the first line, so a full
        // history parse from offset 0 always sees it). A batch that starts mid-session
        // during incremental parsing won't see it and falls back to "unknown", same
        // accepted limitation as `currentModel` above.
        var currentProjectPath = "unknown"
        var latestPrimary: CodexRateLimitWindow?
        var latestSecondary: CodexRateLimitWindow?
        var latestWindowEventTimestamp: Date?

        let newOffset = try ChunkedLineReader.forEachLine(at: url, fromByteOffset: byteOffset) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { return }
            guard let raw = try? JSONDecoder().decode(RawLine.self, from: lineData) else { return }

            if raw.type == "session_meta", let cwd = raw.payload?.cwd {
                currentProjectPath = cwd
                return
            }

            if raw.type == "turn_context", let model = raw.payload?.model {
                currentModel = model
                return
            }

            guard raw.type == "event_msg", raw.payload?.type == "token_count" else { return }
            guard let usage = raw.payload?.info?.last_token_usage else { return }
            guard let timestampString = raw.timestamp, let date = parseDate(timestampString) else { return }

            events.append(CodexUsageEvent(
                timestamp: date,
                model: currentModel,
                inputTokens: usage.input_tokens ?? 0,
                cachedInputTokens: usage.cached_input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                reasoningOutputTokens: usage.reasoning_output_tokens ?? 0,
                sessionId: sessionId,
                projectPath: currentProjectPath
            ))

            if let rateLimits = raw.payload?.rate_limits {
                if let primary = parseWindow(rateLimits.primary, planType: rateLimits.plan_type) {
                    latestPrimary = primary
                }
                if let secondary = parseWindow(rateLimits.secondary, planType: rateLimits.plan_type) {
                    latestSecondary = secondary
                }
                if latestPrimary != nil || latestSecondary != nil {
                    latestWindowEventTimestamp = date
                }
            }
        }

        return ParseResult(
            events: events,
            latestPrimaryWindow: latestPrimary,
            latestSecondaryWindow: latestSecondary,
            latestWindowEventTimestamp: latestWindowEventTimestamp,
            newOffset: newOffset
        )
    }
}
