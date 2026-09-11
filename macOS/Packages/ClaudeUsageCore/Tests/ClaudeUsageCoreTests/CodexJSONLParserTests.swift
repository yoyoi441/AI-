import Testing
import Foundation
@testable import ClaudeUsageCore

struct CodexJSONLParserTests {
    @Test func modelSpecificZeroDoesNotReplaceAccountWideQuota() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let accountWide = #"{"timestamp":"2026-09-11T08:17:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":30.0,"window_minutes":10080,"resets_at":1789459727},"secondary":null,"plan_type":"prolite"}}}"#
        let modelSpecific = #"{"timestamp":"2026-09-11T08:18:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1}},"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1789132709},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1789719509},"plan_type":"prolite"}}}"#
        try (accountWide + "\n" + modelSpecific + "\n").write(to: url, atomically: true, encoding: .utf8)

        let result = try CodexJSONLParser.parseFile(at: url, sessionId: "mixed-limits")
        #expect(result.events.count == 2)
        #expect(result.latestPrimaryWindow?.usedPercent == 30)
        #expect(result.latestPrimaryWindow?.windowMinutes == 10080)
        #expect(result.latestSecondaryWindow == nil)
    }
}
