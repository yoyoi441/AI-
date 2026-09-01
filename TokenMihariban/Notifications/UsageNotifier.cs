using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using TokenMihariban.Sync;

namespace TokenMihariban.Notifications;

/// <summary>
/// Local (on-device) notifications when a user-set token target is exceeded — Windows
/// port of the Mac/iOS/Android <c>UsageNotifier</c>. Uses <see cref="NotifyIcon.ShowBalloonTip"/>
/// rather than the modern toast-notification APIs (which need an AppUserModelID
/// registered via COM for an unpackaged desktop app to reliably show at all) — Windows
/// renders balloon tips with the same Action Center-style look on Windows 10/11, and
/// this path can't silently fail from a registration step gone wrong.
/// </summary>
public static class UsageNotifier
{
    private const string StorageKey = "sentUsageNotificationKeys";

    /// <summary>
    /// Posts a notification the first time <paramref name="dedupeKey"/> is seen, and
    /// never again for that same key — callers pass a key that changes when the
    /// underlying period resets (e.g. includes the calendar date), so exceeding a
    /// target notifies once per day/window rather than on every refresh while still
    /// over it.
    /// </summary>
    public static void NotifyOnce(NotifyIcon trayIcon, string dedupeKey, string title, string body)
    {
        var sent = AppSettings.Shared.GetStringSet(StorageKey);
        if (sent.Contains(dedupeKey)) return;
        sent.Add(dedupeKey);
        if (sent.Count > 200)
        {
            sent = sent.Skip(sent.Count - 100).ToHashSet();
        }
        AppSettings.Shared.SetStringSet(StorageKey, sent);

        trayIcon.BalloonTipTitle = title;
        trayIcon.BalloonTipText = body;
        trayIcon.BalloonTipIcon = ToolTipIcon.Info;
        trayIcon.ShowBalloonTip(8000);
    }
}
