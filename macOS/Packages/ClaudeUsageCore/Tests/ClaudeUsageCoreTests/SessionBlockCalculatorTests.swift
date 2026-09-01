import Testing
import Foundation
@testable import ClaudeUsageCore

struct SessionBlockCalculatorTests {
    private func event(_ isoTimestamp: String, input: Int = 100) -> UsageEvent {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return UsageEvent(
            timestamp: formatter.date(from: isoTimestamp)!,
            model: "claude-sonnet-5",
            inputTokens: input,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            sessionId: "s1",
            projectPath: "/p"
        )
    }

    @Test func consecutiveEventsWithinFiveHoursFormOneBlock() {
        let events = [
            event("2026-07-27T09:15:00Z"),
            event("2026-07-27T10:00:00Z"),
            event("2026-07-27T13:30:00Z") // still within 5h of the 09:00 floor
        ]
        let blocks = SessionBlockCalculator.computeBlocks(from: events)
        #expect(blocks.count == 1)
        #expect(blocks[0].events.count == 3)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(blocks[0].start == formatter.date(from: "2026-07-27T09:00:00Z"))
        #expect(blocks[0].end == formatter.date(from: "2026-07-27T14:00:00Z"))
    }

    @Test func gapOverFiveHoursStartsNewBlock() {
        let events = [
            event("2026-07-27T09:00:00Z"),
            event("2026-07-27T20:00:00Z") // >5h gap
        ]
        let blocks = SessionBlockCalculator.computeBlocks(from: events)
        #expect(blocks.count == 2)
        #expect(blocks[0].events.count == 1)
        #expect(blocks[1].events.count == 1)
    }

    @Test func eventPastBlockEndStartsNewBlockEvenWithoutBigGap() {
        // Steady hourly activity, but a block only spans 5h, so hour 6 must start a new block.
        let events = (0..<7).map { event("2026-07-27T\(String(format: "%02d", 9 + $0)):00:00Z") }
        let blocks = SessionBlockCalculator.computeBlocks(from: events)
        #expect(blocks.count == 2)
        #expect(blocks[0].events.count == 5) // hours 9,10,11,12,13
        #expect(blocks[1].events.count == 2) // hours 14,15
    }

    @Test func activeBlockIsNilOncePastEnd() {
        let events = [event("2026-07-27T09:00:00Z")]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let stillActive = SessionBlockCalculator.activeBlock(from: events, at: formatter.date(from: "2026-07-27T10:00:00Z")!)
        #expect(stillActive != nil)

        let expired = SessionBlockCalculator.activeBlock(from: events, at: formatter.date(from: "2026-07-27T15:00:00Z")!)
        #expect(expired == nil)
    }

    @Test func emptyEventsProduceNoBlocks() {
        #expect(SessionBlockCalculator.computeBlocks(from: []).isEmpty)
        #expect(SessionBlockCalculator.activeBlock(from: [], at: Date()) == nil)
    }
}
