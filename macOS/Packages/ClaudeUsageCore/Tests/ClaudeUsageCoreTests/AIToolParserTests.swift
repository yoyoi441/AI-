import XCTest
@testable import ClaudeUsageCore

final class AIToolParserTests: XCTestCase {
    func testGeminiLegacySessionUsesReportedTotalAndDeduplicatesMessages() throws {
        let json = #"{"sessionId":"s1","directories":["/tmp/project"],"messages":[{"id":"m1","timestamp":"2026-09-13T01:02:03.000Z","type":"gemini","tokens":{"input":100,"output":20,"cached":80,"thoughts":5,"tool":2,"total":127},"model":"gemini-2.5-pro"}]}"#
        let events = GeminiSessionParser.parse(Data(json.utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].totalTokens, 127)
        XCTAssertEqual(events[0].cachedTokens, 80)
        XCTAssertEqual(events[0].projectPath, "/tmp/project")
        XCTAssertEqual(events[0].eventId, "gemini:s1:m1")
    }

    func testGeminiJSONLReadsMetadataAndMessage() {
        let jsonl = """
        {"sessionId":"s2","directories":["C:/work"]}
        {"id":"m2","timestamp":"2026-09-13T01:02:03Z","type":"gemini","tokens":{"input":10,"output":2,"cached":0,"total":12},"model":"gemini-2.5-flash"}
        """
        let events = GeminiSessionParser.parse(Data(jsonl.utf8))
        XCTAssertEqual(events.first?.eventId, "gemini:s2:m2")
        XCTAssertEqual(events.first?.totalTokens, 12)
    }

    func testOpenCodeMessageUsesExplicitTotal() {
        let json = #"{"id":"msg1","sessionID":"ses1","role":"assistant","time":{"created":1789261323000},"providerID":"anthropic","modelID":"claude-sonnet-4","path":{"cwd":"/work","root":"/work"},"tokens":{"total":155,"input":100,"output":25,"reasoning":30,"cache":{"read":50,"write":0}}}"#
        let event = OpenCodeMessageParser.parseMessageData(Data(json.utf8))
        XCTAssertEqual(event?.tool, .openCode)
        XCTAssertEqual(event?.totalTokens, 155)
        XCTAssertEqual(event?.cachedTokens, 50)
        XCTAssertEqual(event?.projectPath, "/work")
    }
}

