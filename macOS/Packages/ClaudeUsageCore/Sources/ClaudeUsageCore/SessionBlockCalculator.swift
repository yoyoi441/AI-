import Foundation

/// Groups usage events into estimated 5-hour session blocks.
///
/// This mirrors the heuristic used by community tools (e.g. ccusage) since Anthropic
/// does not publish how the Pro/Max 5-hour window is actually computed: a new block
/// starts at the top of the hour of the first event after either (a) the previous
/// block ran its full 5 hours, or (b) there was a 5+ hour gap with no activity.
/// Treat the result as an estimate, not an authoritative value.
public enum SessionBlockCalculator {
    public static let blockDuration: TimeInterval = 5 * 3600

    public static func computeBlocks(from events: [UsageEvent]) -> [SessionBlock] {
        guard !events.isEmpty else { return [] }
        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        var blocks: [SessionBlock] = []
        var currentStart: Date?
        var currentEvents: [UsageEvent] = []

        func flush() {
            guard let start = currentStart, !currentEvents.isEmpty else { return }
            blocks.append(SessionBlock(start: start, end: start.addingTimeInterval(blockDuration), events: currentEvents))
        }

        for event in sorted {
            guard let start = currentStart else {
                currentStart = flooredToHour(event.timestamp)
                currentEvents = [event]
                continue
            }

            let blockEnd = start.addingTimeInterval(blockDuration)
            let gapSinceLastEvent = event.timestamp.timeIntervalSince(currentEvents.last?.timestamp ?? start)

            if event.timestamp >= blockEnd || gapSinceLastEvent >= blockDuration {
                flush()
                currentStart = flooredToHour(event.timestamp)
                currentEvents = [event]
            } else {
                currentEvents.append(event)
            }
        }
        flush()

        return blocks
    }

    /// The block still open at `referenceDate`, if any.
    public static func activeBlock(from events: [UsageEvent], at referenceDate: Date) -> SessionBlock? {
        guard let last = computeBlocks(from: events).last else { return nil }
        return referenceDate < last.end ? last : nil
    }

    private static func flooredToHour(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: components) ?? date
    }
}
