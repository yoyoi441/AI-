import Foundation
import UserNotifications

/// Local (on-device) notifications when a user-set token target is exceeded — no
/// server, no push credentials, just `UserNotifications`, which works the same way on
/// macOS and iOS. `@MainActor` because callers (`UsageMonitor`/`MobileUsageMonitor`)
/// are themselves main-actor-isolated and call this synchronously from their refresh
/// cycle — matching that isolation avoids an unnecessary actor hop.
/// Without a delegate, `UNUserNotificationCenter` silently drops notification banners
/// while the app is in the foreground (they still land in Notification Center, just
/// with no visible alert) — since this app is realistically open when a target gets
/// exceeded (it just computed the number), that would make notifications appear to
/// not work at all. This makes foreground notifications behave the same as background
/// ones: banner + sound.
@MainActor
private final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

@MainActor
public enum UsageNotifier {
    public static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundNotificationPresenter.shared

        // The completion-handler API invokes its closure on a private notification
        // queue.  A closure created inside this @MainActor type inherits main-actor
        // isolation under Swift 6, so macOS 26 traps when that private queue calls it.
        // The async API performs the executor hop correctly and avoids crashing the
        // whole menu-bar app immediately after launch.
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Posts a notification the first time `dedupeKey` is seen, and never again for
    /// that same key — callers pass a key that changes when the underlying period
    /// resets (e.g. includes the calendar date), so exceeding a target notifies once
    /// per day/window rather than on every refresh while still over it.
    public static func notifyOnce(dedupeKey: String, title: String, body: String) {
        let defaults = UserDefaults.standard
        let storageKey = "sentUsageNotificationKeys"
        var sent = Set(defaults.stringArray(forKey: storageKey) ?? [])
        guard !sent.contains(dedupeKey) else { return }
        sent.insert(dedupeKey)
        if sent.count > 200 {
            sent = Set(Array(sent).suffix(100))
        }
        defaults.set(Array(sent), forKey: storageKey)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: dedupeKey, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
