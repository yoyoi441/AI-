import Foundation

/// Parses Claude Code's local session transcripts (`~/.claude/projects/**/*.jsonl`).
///
/// Each line is a standalone JSON object; only assistant turns carry a `usage` block,
/// so every other line (user turns, tool results, summaries, ...) is skipped.
public enum JSONLParser {
    private struct RawLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?
            }
            let model: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let message: Message?
        let sessionId: String?
        let cwd: String?
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

    /// Decodes a single JSONL line into a `UsageEvent`, or `nil` if the line isn't a
    /// usage-bearing assistant turn (or isn't valid JSON at all).
    public static func parseLine(_ line: String) -> UsageEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let raw = try? JSONDecoder().decode(RawLine.self, from: data) else { return nil }
        guard raw.type == "assistant", let message = raw.message, let usage = message.usage else { return nil }
        guard let timestampString = raw.timestamp else { return nil }
        guard let date = isoFormatterWithFractionalSeconds.date(from: timestampString)
            ?? isoFormatter.date(from: timestampString) else { return nil }

        return UsageEvent(
            timestamp: date,
            model: message.model ?? "unknown",
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            sessionId: raw.sessionId ?? "unknown",
            projectPath: raw.cwd ?? "unknown"
        )
    }

    /// Reads a log file starting at `byteOffset`, returning newly parsed events and the
    /// byte offset to resume from next time. Only complete lines (ending in `\n`) are
    /// consumed; a trailing partial line (still being written by Claude Code) is left
    /// for the next call so it never gets split across two reads.
    public static func parseFile(at url: URL, fromByteOffset byteOffset: UInt64 = 0) throws -> (events: [UsageEvent], newOffset: UInt64) {
        var events: [UsageEvent] = []
        let newOffset = try ChunkedLineReader.forEachLine(at: url, fromByteOffset: byteOffset) { line in
            if let event = parseLine(line) {
                events.append(event)
            }
        }
        return (events, newOffset)
    }
}
