using System;
using TokenMihariban.Models;

namespace TokenMihariban.Logic;

/// <summary>
/// Predicts whether the *current* Claude Code block is on track to hit its token target
/// before the block itself resets, so the user gets a heads-up minutes ahead of time
/// instead of only finding out once already over. Port of the Mac/iOS/Android
/// `PaceAlertEvaluator` — keep all four in sync.
/// </summary>
public static class PaceAlertEvaluator
{
    private const double MinimumElapsedMinutes = 5;
    public const double WarnWithinMinutes = 20;

    /// <summary>
    /// Returns the estimated number of minutes until <paramref name="block"/> reaches
    /// <paramref name="target"/> tokens at its observed average pace so far, or null when
    /// there isn't enough signal (block just started, already at/past target, usage is
    /// flat, or the projection lands after the block would reset on its own anyway).
    /// </summary>
    public static double? MinutesUntilTargetReached(SessionBlockSummary block, long target, DateTime? now = null)
    {
        var currentTime = now ?? DateTime.UtcNow;
        if (target <= 0 || block.TotalTokens >= target) return null;

        var elapsedMinutes = (currentTime - block.Start).TotalMinutes;
        if (elapsedMinutes < MinimumElapsedMinutes) return null;

        var rate = block.TotalTokens / elapsedMinutes;
        if (rate <= 0) return null;

        var minutesUntilTarget = (target - block.TotalTokens) / rate;
        var minutesUntilBlockEnd = (block.End - currentTime).TotalMinutes;
        if (minutesUntilTarget >= minutesUntilBlockEnd) return null;

        return minutesUntilTarget;
    }
}
