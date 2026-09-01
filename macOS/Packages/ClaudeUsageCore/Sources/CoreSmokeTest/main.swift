import ClaudeUsageCore
import Foundation

// Plain-Swift mirror of ClaudeUsageCoreTests, runnable with `swift run CoreSmokeTest`
// on machines without Xcode's XCTest/Testing frameworks. Keep in sync with the real
// test target; this is a fallback, not a replacement.

var failures = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        failures += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

func isoDate(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)!
}

func makeEvent(_ isoTimestamp: String, input: Int = 100) -> UsageEvent {
    UsageEvent(
        timestamp: isoDate(isoTimestamp),
        model: "claude-sonnet-5",
        inputTokens: input,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        sessionId: "s1",
        projectPath: "/p"
    )
}

// MARK: - JSONLParser

do {
    let line = """
    {"type":"assistant","timestamp":"2026-07-27T07:51:37.500Z","sessionId":"abc-123","cwd":"/Users/test/project","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"output_tokens":230,"cache_creation_input_tokens":563,"cache_read_input_tokens":56101}}}
    """
    let event = JSONLParser.parseLine(line)
    check(event?.model == "claude-sonnet-5", "parseLine: model")
    check(event?.inputTokens == 2, "parseLine: inputTokens")
    check(event?.outputTokens == 230, "parseLine: outputTokens")
    check(event?.cacheCreationTokens == 563, "parseLine: cacheCreationTokens")
    check(event?.cacheReadTokens == 56101, "parseLine: cacheReadTokens")
    check(event?.sessionId == "abc-123", "parseLine: sessionId")
    check(event?.projectPath == "/Users/test/project", "parseLine: projectPath")
}

check(JSONLParser.parseLine(#"{"type":"user","timestamp":"2026-07-27T07:51:37.500Z","message":{"role":"user"}}"#) == nil, "parseLine: skips non-assistant turns")
check(JSONLParser.parseLine(#"{"type":"assistant","timestamp":"2026-07-27T07:51:37.500Z","message":{"model":"claude-sonnet-5"}}"#) == nil, "parseLine: skips assistant turns without usage")
check(JSONLParser.parseLine("not json") == nil, "parseLine: skips malformed JSON")
check(JSONLParser.parseLine("") == nil, "parseLine: skips empty string")

do {
    let tempDir = FileManager.default.temporaryDirectory
    let url = tempDir.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let line1 = #"{"type":"assistant","timestamp":"2026-07-27T07:00:00.000Z","sessionId":"s1","cwd":"/p","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    let line2 = #"{"type":"assistant","timestamp":"2026-07-27T07:05:00.000Z","sessionId":"s1","cwd":"/p","message":{"model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":15,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    let partialLine = #"{"type":"assistant","timestamp":"2026-07-27T07:10:00.000"#

    try (line1 + "\n" + line2 + "\n" + partialLine).write(to: url, atomically: true, encoding: .utf8)

    let firstRead = try JSONLParser.parseFile(at: url, fromByteOffset: 0)
    check(firstRead.events.count == 2, "parseFile: reads complete lines only")
    check(firstRead.events.map(\.inputTokens) == [10, 5], "parseFile: values in order")

    let expectedOffset = UInt64((line1 + "\n" + line2 + "\n").utf8.count)
    check(firstRead.newOffset == expectedOffset, "parseFile: offset excludes partial trailing line")

    let secondRead = try JSONLParser.parseFile(at: url, fromByteOffset: firstRead.newOffset)
    check(secondRead.events.count == 0, "parseFile: no new events while partial line is still incomplete")
    check(secondRead.newOffset == firstRead.newOffset, "parseFile: offset unchanged while partial line is still incomplete")

    let rest = #"Z","sessionId":"s1","cwd":"/p","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
    let handle = try FileHandle(forWritingTo: url)
    handle.seekToEndOfFile()
    handle.write(rest.data(using: .utf8)!)
    try handle.close()

    let thirdRead = try JSONLParser.parseFile(at: url, fromByteOffset: firstRead.newOffset)
    check(thirdRead.events.count == 1, "parseFile: picks up completed line on next read")
    check(thirdRead.events.first?.inputTokens == 1, "parseFile: completed line value correct")
} catch {
    failures += 1
    print("FAIL parseFile test threw: \(error)")
}

// MARK: - SessionBlockCalculator

do {
    let events = [makeEvent("2026-07-27T09:15:00Z"), makeEvent("2026-07-27T10:00:00Z"), makeEvent("2026-07-27T13:30:00Z")]
    let blocks = SessionBlockCalculator.computeBlocks(from: events)
    check(blocks.count == 1, "computeBlocks: events within 5h form one block")
    check(blocks.first?.events.count == 3, "computeBlocks: block contains all 3 events")
    check(blocks.first?.start == isoDate("2026-07-27T09:00:00Z"), "computeBlocks: start floored to the hour")
    check(blocks.first?.end == isoDate("2026-07-27T14:00:00Z"), "computeBlocks: end is start + 5h")
}

do {
    let events = [makeEvent("2026-07-27T09:00:00Z"), makeEvent("2026-07-27T20:00:00Z")]
    let blocks = SessionBlockCalculator.computeBlocks(from: events)
    check(blocks.count == 2, "computeBlocks: >5h gap starts a new block")
}

do {
    let events = (0..<7).map { makeEvent("2026-07-27T\(String(format: "%02d", 9 + $0)):00:00Z") }
    let blocks = SessionBlockCalculator.computeBlocks(from: events)
    check(blocks.count == 2, "computeBlocks: steady activity still splits at 5h boundary")
    check(blocks.first?.events.count == 5, "computeBlocks: first block has 5 events")
    check(blocks.last?.events.count == 2, "computeBlocks: second block has 2 events")
}

do {
    let events = [makeEvent("2026-07-27T09:00:00Z")]
    check(SessionBlockCalculator.activeBlock(from: events, at: isoDate("2026-07-27T10:00:00Z")) != nil, "activeBlock: active before end")
    check(SessionBlockCalculator.activeBlock(from: events, at: isoDate("2026-07-27T15:00:00Z")) == nil, "activeBlock: nil after end")
}

check(SessionBlockCalculator.computeBlocks(from: []).isEmpty, "computeBlocks: empty input produces no blocks")
check(SessionBlockCalculator.activeBlock(from: [], at: Date()) == nil, "activeBlock: empty input has no active block")

// MARK: - CodexJSONLParser

do {
    let tempDir = FileManager.default.temporaryDirectory
    let url = tempDir.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let turnContext = #"{"timestamp":"2026-07-26T18:01:01.792Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
    let tokenCount = #"{"timestamp":"2026-07-26T18:01:08.808Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20577,"cached_input_tokens":14080,"cache_write_input_tokens":0,"output_tokens":232,"reasoning_output_tokens":17,"total_tokens":20809}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":6.0,"window_minutes":300,"resets_at":1785611970},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1786000000},"plan_type":"plus"}}}"#
    let unrelated = #"{"timestamp":"2026-07-26T18:01:09.000Z","type":"event_msg","payload":{"type":"thread_settings_applied"}}"#

    try (turnContext + "\n" + tokenCount + "\n" + unrelated + "\n").write(to: url, atomically: true, encoding: .utf8)

    let result = try CodexJSONLParser.parseFile(at: url, sessionId: "test-session")
    check(result.events.count == 1, "CodexJSONLParser: parses exactly the token_count line")
    check(result.events.first?.model == "gpt-5.6-sol", "CodexJSONLParser: model carried over from turn_context")
    check(result.events.first?.inputTokens == 20577, "CodexJSONLParser: inputTokens")
    check(result.events.first?.outputTokens == 232, "CodexJSONLParser: outputTokens")
    check(result.events.first?.cachedInputTokens == 14080, "CodexJSONLParser: cachedInputTokens")
    check(result.latestPrimaryWindow?.usedPercent == 6.0, "CodexJSONLParser: primary window used_percent")
    check(result.latestPrimaryWindow?.windowMinutes == 300, "CodexJSONLParser: primary window_minutes")
    check(result.latestPrimaryWindow?.resetsAt == Date(timeIntervalSince1970: 1785611970), "CodexJSONLParser: primary resets_at")
    check(result.latestSecondaryWindow?.windowMinutes == 10080, "CodexJSONLParser: secondary window_minutes")
    check(result.latestPrimaryWindow?.planType == "plus", "CodexJSONLParser: plan_type")
} catch {
    failures += 1
    print("FAIL CodexJSONLParser synthetic test threw: \(error)")
}

// Best-effort probe against this machine's real Codex CLI logs, if present. Doesn't
// fail the suite if Codex isn't installed — just reports what it found.
do {
    let codexSessions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    if let enumerator = FileManager.default.enumerator(at: codexSessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
        if let sample = files.first {
            let result = try CodexJSONLParser.parseFile(at: sample, sessionId: sample.deletingPathExtension().lastPathComponent)
            print("Codex real-data probe: \(sample.lastPathComponent) -> \(result.events.count) events, primary=\(String(describing: result.latestPrimaryWindow)), secondary=\(String(describing: result.latestSecondaryWindow))")
        } else {
            print("Codex real-data probe: no rollout-*.jsonl files found under \(codexSessions.path)")
        }
    }
} catch {
    print("Codex real-data probe threw (non-fatal): \(error)")
}

// MARK: - Result

if failures == 0 {
    print("OK: all checks passed")
} else {
    print("\(failures) check(s) failed")
    exit(1)
}
