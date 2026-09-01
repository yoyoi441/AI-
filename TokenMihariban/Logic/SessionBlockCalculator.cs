using System;
using System.Collections.Generic;
using System.Linq;
using TokenMihariban.Models;

namespace TokenMihariban.Logic;

/// <summary>
/// Groups usage events into estimated 5-hour session blocks — same heuristic as every
/// other platform (community "ccusage"-style): a block starts at the top of the hour of
/// the first event after either a full 5 hours elapsed or a 5+ hour activity gap.
/// Anthropic doesn't publish the real algorithm; treat this as an estimate.
/// </summary>
public static class SessionBlockCalculator
{
    public static readonly TimeSpan BlockDuration = TimeSpan.FromHours(5);

    public static List<SessionBlock> ComputeBlocks(IReadOnlyList<UsageEvent> events)
    {
        var blocks = new List<SessionBlock>();
        if (events.Count == 0) return blocks;

        var sorted = events.OrderBy(e => e.Timestamp).ToList();

        DateTime? currentStart = null;
        var currentEvents = new List<UsageEvent>();

        void Flush()
        {
            if (currentStart is not { } start || currentEvents.Count == 0) return;
            blocks.Add(new SessionBlock(start, start + BlockDuration, currentEvents.ToList()));
        }

        foreach (var evt in sorted)
        {
            if (currentStart is not { } start)
            {
                currentStart = FlooredToHourUtc(evt.Timestamp);
                currentEvents = new List<UsageEvent> { evt };
                continue;
            }

            var blockEnd = start + BlockDuration;
            var lastEventTime = currentEvents.Count > 0 ? currentEvents[^1].Timestamp : start;
            var gapSinceLastEvent = evt.Timestamp - lastEventTime;

            if (evt.Timestamp >= blockEnd || gapSinceLastEvent >= BlockDuration)
            {
                Flush();
                currentStart = FlooredToHourUtc(evt.Timestamp);
                currentEvents = new List<UsageEvent> { evt };
            }
            else
            {
                currentEvents.Add(evt);
            }
        }
        Flush();

        return blocks;
    }

    /// <summary>
    /// Matches the Mac/iOS/Android apps' explicit UTC flooring — block boundaries must
    /// line up across platforms and show the same
    /// current block/reset time regardless of which device's clock/timezone computed it.
    /// </summary>
    private static DateTime FlooredToHourUtc(DateTime date)
    {
        var utc = date.Kind == DateTimeKind.Utc ? date : date.ToUniversalTime();
        return new DateTime(utc.Year, utc.Month, utc.Day, utc.Hour, 0, 0, DateTimeKind.Utc);
    }
}
