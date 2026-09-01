import Testing
import Foundation
@testable import ClaudeUsageCore

struct JSONLParserTests {
    @Test func parseLineExtractsUsageFromAssistantTurn() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-07-27T07:51:37.500Z","sessionId":"abc-123","cwd":"/Users/test/project","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"output_tokens":230,"cache_creation_input_tokens":563,"cache_read_input_tokens":56101}}}
        """
        let event = try #require(JSONLParser.parseLine(line))
        #expect(event.model == "claude-sonnet-5")
        #expect(event.inputTokens == 2)
        #expect(event.outputTokens == 230)
        #expect(event.cacheCreationTokens == 563)
        #expect(event.cacheReadTokens == 56101)
        #expect(event.sessionId == "abc-123")
        #expect(event.projectPath == "/Users/test/project")
    }

    @Test func parseLineSkipsNonAssistantTurns() {
        let line = """
        {"type":"user","timestamp":"2026-07-27T07:51:37.500Z","message":{"role":"user"}}
        """
        #expect(JSONLParser.parseLine(line) == nil)
    }

    @Test func parseLineSkipsAssistantTurnsWithoutUsage() {
        let line = """
        {"type":"assistant","timestamp":"2026-07-27T07:51:37.500Z","message":{"model":"claude-sonnet-5"}}
        """
        #expect(JSONLParser.parseLine(line) == nil)
    }

    @Test func parseLineSkipsMalformedJSON() {
        #expect(JSONLParser.parseLine("not json") == nil)
        #expect(JSONLParser.parseLine("") == nil)
    }

    @Test func parseFileOnlyConsumesCompleteLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let line1 = #"{"type":"assistant","timestamp":"2026-07-27T07:00:00.000Z","sessionId":"s1","cwd":"/p","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let line2 = #"{"type":"assistant","timestamp":"2026-07-27T07:05:00.000Z","sessionId":"s1","cwd":"/p","message":{"model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":15,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let partialLine = #"{"type":"assistant","timestamp":"2026-07-27T07:10:00.000"# // no trailing newline, incomplete

        try (line1 + "\n" + line2 + "\n" + partialLine).write(to: url, atomically: true, encoding: .utf8)

        let firstRead = try JSONLParser.parseFile(at: url, fromByteOffset: 0)
        #expect(firstRead.events.count == 2)
        #expect(firstRead.events.map(\.inputTokens) == [10, 5])

        // The partial trailing line must not have been consumed.
        let expectedOffset = UInt64((line1 + "\n" + line2 + "\n").utf8.count)
        #expect(firstRead.newOffset == expectedOffset)

        // Nothing new yet: the partial line still isn't terminated.
        let secondRead = try JSONLParser.parseFile(at: url, fromByteOffset: firstRead.newOffset)
        #expect(secondRead.events.count == 0)
        #expect(secondRead.newOffset == firstRead.newOffset)

        // Complete the partial line and append a new one.
        let rest = #"Z","sessionId":"s1","cwd":"/p","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(rest.data(using: .utf8)!)
        try handle.close()

        let thirdRead = try JSONLParser.parseFile(at: url, fromByteOffset: firstRead.newOffset)
        #expect(thirdRead.events.count == 1)
        #expect(thirdRead.events[0].inputTokens == 1)
    }
}
