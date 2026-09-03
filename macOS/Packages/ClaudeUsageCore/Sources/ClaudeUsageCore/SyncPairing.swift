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
        get { normalize(UserDefaults.standard.string(forKey: syncIdKey)) }
        set {
            if let normalized = normalize(newValue) {
                UserDefaults.standard.set(normalized, forKey: syncIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: syncIdKey)
            }
        }
    }

    /// Generates a new random pairing code for this device to be the "first" device in a
    /// sync group. Other devices then enter this same code to join.
    @discardableResult
    public static func generateNewSyncId() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // no 0/O/1/I ambiguity
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    public static func normalize(_ code: String?) -> String? {
        guard let code else { return nil }
        let normalized = code.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        guard normalized.count == 16,
              normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return normalized
    }

    public static func formatted(_ code: String) -> String {
        stride(from: 0, to: 16, by: 4).map { offset in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: 4)
            return String(code[start..<end])
        }.joined(separator: "-")
    }
}
