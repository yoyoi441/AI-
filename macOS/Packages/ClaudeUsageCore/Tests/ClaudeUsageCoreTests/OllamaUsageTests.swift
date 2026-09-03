import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Ollama usage")
struct OllamaUsageTests {
    @Test("NDJSONの最終応答からトークン数とモデルを取得する")
    func parsesStreamingResponse() throws {
        let body = """
        {"model":"qwen3:8b","response":"途中","done":false}
        {"model":"qwen3:8b","done":true,"prompt_eval_count":120,"eval_count":45,"total_duration":9000}
        """.data(using: .utf8)!

        let event = try #require(OllamaUsageResponseParser.parse(
            body,
            requestedModel: nil,
            forceCloud: false,
            requestId: "request-1"
        ))

        #expect(event.model == "qwen3:8b")
        #expect(event.inputTokens == 120)
        #expect(event.outputTokens == 45)
        #expect(event.source == .local)
        #expect(event.requestId == "request-1")
    }

    @Test(":cloudモデルをクラウド使用量として判定する")
    func detectsCloudModel() throws {
        let body = #"{"model":"gpt-oss:20b:cloud","done":true,"prompt_eval_count":1000000,"eval_count":1000000}"#.data(using: .utf8)!
        let event = try #require(OllamaUsageResponseParser.parse(body, requestedModel: nil, forceCloud: false))
        #expect(event.source == .cloud)
    }

    @Test("表示は合算しつつ内部ではモデルと接続先を保持する")
    func aggregatesOneRingWithHiddenBreakdown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T12:00:00Z"))
        let events = [
            OllamaUsageEvent(timestamp: now.addingTimeInterval(-60), model: "qwen3:8b", inputTokens: 100, outputTokens: 50, totalDurationNanoseconds: 1, source: .local, requestId: "local"),
            OllamaUsageEvent(timestamp: now.addingTimeInterval(-30), model: "gpt-oss:20b:cloud", inputTokens: 200, outputTokens: 100, totalDurationNanoseconds: 2, source: .cloud, requestId: "cloud")
        ]

        let snapshot = OllamaUsageComputer.compute(events: events, dailyTokenTarget: 1_000, colorHex: "#F97316", now: now, calendar: calendar)
        #expect(snapshot.todayTotalTokens == 450)
        #expect(snapshot.todayLocalTokens == 150)
        #expect(snapshot.todayCloudTokens == 300)
        #expect(snapshot.todayModelBreakdown.count == 2)
        #expect(snapshot.targetFraction == 0.45)
        #expect(snapshot.todayCloudEstimatedCostUSD > 0)
    }
}
