import Foundation

/// A user-defined daily time-of-day range (e.g. "my work hours: 9:00-18:00") used for
/// the custom-window token usage gauge. Stored as minutes-since-midnight so it's just
/// two Ints to persist and compare against a Date's time-of-day components — no
/// timezone/DST edge cases beyond what `Calendar.current` already handles for any
/// other time-of-day computation in this app.
public struct DailyTimeWindow: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public static let `default` = DailyTimeWindow(startMinute: 9 * 60, endMinute: 18 * 60)

    public func rangeText() -> String {
        String(format: "%02d:%02d-%02d:%02d", startMinute / 60, startMinute % 60, endMinute / 60, endMinute % 60)
    }
}

public extension Array where Element == HourlyUsagePoint {
    /// Sums tokens from today's hourly buckets whose hour falls within
    /// `[startMinute, endMinute)` of the day. `endMinute < startMinute` is treated as
    /// an overnight window (e.g. 22:00-06:00) that wraps past midnight.
    func tokensInWindow(_ window: DailyTimeWindow, calendar: Calendar = .current) -> Int {
        reduce(0) { total, point in
            let comps = calendar.dateComponents([.hour, .minute], from: point.hourStart)
            let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let inWindow: Bool
            if window.startMinute <= window.endMinute {
                inWindow = minuteOfDay >= window.startMinute && minuteOfDay < window.endMinute
            } else {
                inWindow = minuteOfDay >= window.startMinute || minuteOfDay < window.endMinute
            }
            return inWindow ? total + point.tokens : total
        }
    }
}
