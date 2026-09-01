import Foundation

/// Identifies "this install" (`deviceId`, used to avoid double-counting your own events
/// when they come back from the cloud) and "which group of devices to sync with"
/// (`syncId`, shared across your own Mac/iPhone/etc. by copying a code between them).
public enum SyncPairing {
    private static let deviceIdKey = "syncDeviceId"
    private static let syncIdKey = "syncGroupId"

    /// Stable per-install identifier. Generated once and persisted; never regenerated.
    public static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIdKey)
        return generated
    }

    /// The shared "sync group" code. `nil` until the user either generates one (first
    /// device to set this up) or pairs to an existing one (enters a code shown on
    /// another device).
    public static var syncId: String? {
        get { UserDefaults.standard.string(forKey: syncIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncIdKey) }
    }

    /// Generates a new random pairing code for this device to be the "first" device in a
    /// sync group. Other devices then enter this same code to join.
    @discardableResult
    public static func generateNewSyncId() -> String {
        // Short enough to type/copy comfortably, long enough (36^8 ≈ 2.8e12 combinations)
        // that guessing another user's code by chance is impractical.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // no 0/O/1/I ambiguity
        let code = String((0..<8).map { _ in alphabet.randomElement()! })
        syncId = code
        return code
    }
}
