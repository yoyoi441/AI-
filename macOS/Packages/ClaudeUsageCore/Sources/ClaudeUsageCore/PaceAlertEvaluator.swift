import Foundation

/// Predicts whether the *current* Claude Code block is on track to hit its token target
/// before the block itself resets, so the user can get a heads-up minutes ahead of time
/// instead of only finding out once they're already over. Scoped to Claude Code's block
/// gauge specifically: it's the one number in this app with no forward-looking signal at
/// all today (unlike Codex, where OpenAI's own `used_percent` already updates live, or
/// the daily/window targets, which already notify once actually exceeded).
public enum PaceAlertEvaluator {
    /// Minimum elapsed time before trusting the observed rate — a block that just
    /// started has too little signal (one large call could 10x the "rate" a minute in).
    private static let minimumElapsedMinutes: Double = 5
    /// How far ahead a prediction has to reach to be worth surfacing — closer than this
    /// and the existing "exceeded" state (a red gauge) will speak for itself soon anyway.
    public static let warnWithinMinutes: Double = 20

    /// Returns the estimated number of minutes until `block` reaches `target` tokens at
    /// its observed average pace so far, or nil when there isn't enough signal to say
    /// anything (block just started, already at/past target, usage is flat, or the
    /// projection lands after the block would reset on its own anyway).
    public static func minutesUntilTargetReached(block: SessionBlockSummary, target: Int, now: Date = Date()) -> Double? {
        guard target > 0, block.totalTokens < target else { return nil }
        let elapsedMinutes = now.timeIntervalSince(block.start) / 60
        guard elapsedMinutes >= minimumElapsedMinutes else { return nil }

        let rate = Double(block.totalTokens) / elapsedMinutes
        guard rate > 0 else { return nil }

        let minutesUntilTarget = Double(target - block.totalTokens) / rate
        let minutesUntilBlockEnd = block.end.timeIntervalSince(now) / 60
        guard minutesUntilTarget < minutesUntilBlockEnd else { return nil }

        return minutesUntilTarget
    }
}
