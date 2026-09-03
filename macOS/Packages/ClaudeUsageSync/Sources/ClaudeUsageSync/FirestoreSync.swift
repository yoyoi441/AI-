import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import ClaudeUsageCore

/// Cross-device sync via Firebase Firestore. Every device that runs this app parses its
/// own local logs and uploads new events here; every device (including ones with no
/// local logs at all, like a phone) downloads everyone else's events and folds them into
/// its own computation, so the 5-hour block / token totals reflect *all* devices, not
/// just the one you're looking at.
///
/// No Anthropic/OpenAI credentials are involved — only token-usage counts.
///
/// Each installation receives a persistent anonymous Firebase identity. Devices join a
/// group using a random 16-character capability code (~80 bits), and Firestore Security
/// Rules restrict every group document to authenticated members.
/// Firestore layout: `syncGroups/{syncId}/claudeEvents/{docId}`,
/// `.../codexEvents/{docId}`, `.../codexRateLimits/latest`.
///
/// Shared as its own package (rather than living in `ClaudeUsageCore`) so widget
/// extensions never link Firebase at all — only the two full apps (Mac, iOS) need this.
///
/// Deliberately *not* `@MainActor`: the Firestore SDK invokes listener/transaction/
/// commit closures on its own internal dispatch queues, not the main thread. Marking
/// this type (or its closures) MainActor-isolated caused a hard runtime crash
/// (`dispatch_assert_queue_fail`) the moment a transaction closure ran off-queue.
/// Callers that need to touch `@MainActor` state from these callbacks hop explicitly
/// (`Task { @MainActor in ... }`), same as `UsageMonitor`/`MobileUsageMonitor` already do.
public enum FirestoreSync {
    // Only ever set from configureIfNeeded(), which every call site invokes before
    // touching Firestore; safe as plain mutable state without actor isolation.
    nonisolated(unsafe) private static var didConfigure = false
    nonisolated(unsafe) private static var readyGroups = Set<String>()
    private static let readyGroupsLock = NSLock()

    /// True once Firebase has a config to use. If the developer hasn't dropped in
    /// `GoogleService-Info.plist` yet, every sync operation becomes a no-op — the app
    /// keeps working exactly as it did before Firebase existed (local-only).
    public static var isAvailable: Bool {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let settings = NSDictionary(contentsOfFile: path) as? [String: Any],
              let projectId = settings["PROJECT_ID"] as? String,
              let apiKey = settings["API_KEY"] as? String,
              !projectId.isEmpty, projectId != "disabled",
              !apiKey.isEmpty, apiKey != "disabled" else { return false }
        return true
    }

    public static func configureIfNeeded() {
        guard isAvailable, !didConfigure else { return }
        FirebaseApp.configure()
        // The SDK's default persistent (leveldb-backed) cache size is *unlimited* — for a
        // sync group that has been accumulating events across devices for months, that
        // cache (plus the in-memory document snapshots rebuilt from it on every listener
        // fire) was observed driving this menu bar app's RSS well past 1GB. Bounding it
        // makes the SDK evict old cached documents instead of keeping every one it has
        // ever seen; the app only ever displays today/7-day rollups, so a small cache is
        // enough — Firestore just re-fetches from the server on the rare cache miss.
        let settings = Firestore.firestore().settings
        settings.cacheSettings = PersistentCacheSettings(sizeBytes: 40 * 1024 * 1024 as NSNumber)
        Firestore.firestore().settings = settings
        didConfigure = true
    }

    private static var db: Firestore? {
        guard didConfigure else { return nil }
        return Firestore.firestore()
    }

    private static func groupRef(syncId: String) -> DocumentReference? {
        db?.collection("syncGroups").document(syncId)
    }

    public static func isReady(syncId: String) -> Bool {
        readyGroupsLock.lock()
        defer { readyGroupsLock.unlock() }
        return readyGroups.contains(syncId)
    }

    private static func setReady(_ ready: Bool, syncId: String) {
        readyGroupsLock.lock()
        if ready { readyGroups.insert(syncId) } else { readyGroups.remove(syncId) }
        readyGroupsLock.unlock()
    }

    /// Authenticates this installation and creates/joins the group membership checked by
    /// Firestore rules. FirebaseAuth persists the anonymous account in the Keychain.
    public static func activatePairing(
        syncId: String,
        deviceId: String,
        createGroup: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let normalized = SyncPairing.normalize(syncId) else {
            completion(.failure(PairingError.invalidCode))
            return
        }
        ensureAuthenticated { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let user):
                guard let group = groupRef(syncId: normalized), let db else {
                    completion(.failure(PairingError.firebaseUnavailable))
                    return
                }
                let batch = db.batch()
                if createGroup {
                    batch.setData([
                        "ownerUid": user.uid,
                        "createdAt": Timestamp(date: Date()),
                        "schemaVersion": 2
                    ], forDocument: group)
                }
                batch.setData([
                    "deviceId": deviceId,
                    "platform": "macos",
                    "joinedAt": Timestamp(date: Date())
                ], forDocument: group.collection("members").document(user.uid))
                batch.commit { error in
                    if let error { completion(.failure(error)); return }
                    setReady(true, syncId: normalized)
                    completion(.success(()))
                }
            }
        }
    }

    public static func unpair(syncId: String, completion: @escaping () -> Void) {
        guard let normalized = SyncPairing.normalize(syncId) else { completion(); return }
        ensureAuthenticated { result in
            guard case .success(let user) = result,
                  let group = groupRef(syncId: normalized) else {
                setReady(false, syncId: normalized)
                completion()
                return
            }
            group.collection("members").document(user.uid).delete { _ in
                setReady(false, syncId: normalized)
                completion()
            }
        }
    }

    private static func ensureAuthenticated(completion: @escaping (Result<User, Error>) -> Void) {
        configureIfNeeded()
        guard didConfigure else {
            completion(.failure(PairingError.firebaseUnavailable))
            return
        }
        if let user = Auth.auth().currentUser {
            completion(.success(user))
            return
        }
        Auth.auth().signInAnonymously { result, error in
            if let error { completion(.failure(error)); return }
            guard let user = result?.user else {
                completion(.failure(PairingError.authenticationFailed))
                return
            }
            completion(.success(user))
        }
    }

    private enum PairingError: Error {
        case invalidCode
        case firebaseUnavailable
        case authenticationFailed
    }

    // MARK: - Claude events

    private struct ClaudeEventDocument: Codable {
        let deviceId: String
        let event: UsageEvent
    }

    public static func uploadClaudeEvents(_ events: [UsageEvent], syncId: String, deviceId: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard isReady(syncId: syncId), let group = groupRef(syncId: syncId), !events.isEmpty else { completion(false); return }
        let batch = db!.batch()
        for event in events {
            let docId = documentId(deviceId: deviceId, sessionId: event.sessionId, timestamp: event.timestamp)
            let ref = group.collection("claudeEvents").document(docId)
            guard let data = try? Firestore.Encoder().encode(ClaudeEventDocument(deviceId: deviceId, event: event)) else { continue }
            batch.setData(data, forDocument: ref)
        }
        batch.commit { error in
            if let error { print("FirestoreSync: claude upload failed: \(error)") }
            completion(error == nil)
        }
    }

    // The UI only ever surfaces today/7-day rollups (see `SnapshotComputer`), but the
    // *listener* itself has no such window: without one it subscribes to the entire
    // collection, and every single change (any device, any event, ever) forces a full
    // re-fetch/re-decode of every document the sync group has accumulated since pairing
    // — for a months-old group this was the largest single contributor to the memory
    // growth reported in Activity Monitor. A generous 9-day floor (a full day of margin
    // past the 7-day chart, to also cover the 5-hour block never straddling the cutoff)
    // keeps the listener's working set bounded to what the app can actually show.
    private static var recentEventsCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -9, to: Date()) ?? Date.distantPast
    }

    public static func observeClaudeEvents(syncId: String, excludingDeviceId: String, onChange: @escaping ([UsageEvent]) -> Void) -> ListenerRegistration? {
        groupRef(syncId: syncId)?.collection("claudeEvents")
            .whereField("event.timestamp", isGreaterThanOrEqualTo: Timestamp(date: recentEventsCutoff))
            .addSnapshotListener { snapshot, error in
            guard let snapshot else {
                if let error { print("FirestoreSync: claude listen failed: \(error)") }
                return
            }
            let events = snapshot.documents.compactMap { doc -> UsageEvent? in
                guard let decoded = try? doc.data(as: ClaudeEventDocument.self), decoded.deviceId != excludingDeviceId else { return nil }
                return decoded.event
            }
            onChange(events)
        }
    }

    // MARK: - Codex events

    private struct CodexEventDocument: Codable {
        let deviceId: String
        let event: CodexUsageEvent
    }

    public static func uploadCodexEvents(_ events: [CodexUsageEvent], syncId: String, deviceId: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard isReady(syncId: syncId), let group = groupRef(syncId: syncId), !events.isEmpty else { completion(false); return }
        let batch = db!.batch()
        for event in events {
            let docId = documentId(deviceId: deviceId, sessionId: event.sessionId, timestamp: event.timestamp)
            let ref = group.collection("codexEvents").document(docId)
            guard let data = try? Firestore.Encoder().encode(CodexEventDocument(deviceId: deviceId, event: event)) else { continue }
            batch.setData(data, forDocument: ref)
        }
        batch.commit { error in
            if let error { print("FirestoreSync: codex upload failed: \(error)") }
            completion(error == nil)
        }
    }

    public static func observeCodexEvents(syncId: String, excludingDeviceId: String, onChange: @escaping ([CodexUsageEvent]) -> Void) -> ListenerRegistration? {
        groupRef(syncId: syncId)?.collection("codexEvents")
            .whereField("event.timestamp", isGreaterThanOrEqualTo: Timestamp(date: recentEventsCutoff))
            .addSnapshotListener { snapshot, error in
            guard let snapshot else {
                if let error { print("FirestoreSync: codex listen failed: \(error)") }
                return
            }
            let events = snapshot.documents.compactMap { doc -> CodexUsageEvent? in
                guard let decoded = try? doc.data(as: CodexEventDocument.self), decoded.deviceId != excludingDeviceId else { return nil }
                return decoded.event
            }
            onChange(events)
        }
    }

    // MARK: - Ollama events

    private struct OllamaEventDocument: Codable {
        let deviceId: String
        let event: OllamaUsageEvent
    }

    public static func uploadOllamaEvents(_ events: [OllamaUsageEvent], syncId: String, deviceId: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard isReady(syncId: syncId), let group = groupRef(syncId: syncId), !events.isEmpty else { completion(false); return }
        let batch = db!.batch()
        for event in events {
            let docId = documentId(deviceId: deviceId, sessionId: event.requestId, timestamp: event.timestamp)
            let ref = group.collection("ollamaEvents").document(docId)
            guard let data = try? Firestore.Encoder().encode(OllamaEventDocument(deviceId: deviceId, event: event)) else { continue }
            batch.setData(data, forDocument: ref)
        }
        batch.commit { error in
            if let error { print("FirestoreSync: Ollama upload failed: \(error)") }
            completion(error == nil)
        }
    }

    public static func observeOllamaEvents(syncId: String, excludingDeviceId: String, onChange: @escaping ([OllamaUsageEvent]) -> Void) -> ListenerRegistration? {
        groupRef(syncId: syncId)?.collection("ollamaEvents")
            .whereField("event.timestamp", isGreaterThanOrEqualTo: Timestamp(date: recentEventsCutoff))
            .addSnapshotListener { snapshot, error in
            guard let snapshot else {
                if let error { print("FirestoreSync: Ollama listen failed: \(error)") }
                return
            }
            let events = snapshot.documents.compactMap { doc -> OllamaUsageEvent? in
                guard let decoded = try? doc.data(as: OllamaEventDocument.self), decoded.deviceId != excludingDeviceId else { return nil }
                return decoded.event
            }
            onChange(events)
        }
    }

    // MARK: - Codex rate limits (already account-wide/official — just relay whichever
    // device saw the newest reading, no merging needed)

    private struct CodexRateLimitsDocument: Codable {
        let deviceId: String
        let eventTimestamp: Date
        let primary: CodexRateLimitWindow?
        let secondary: CodexRateLimitWindow?
    }

    /// Overwrites the shared "latest reading" only if this one is actually newer, using a
    /// transaction so two devices racing to update don't clobber a newer value with an
    /// older one.
    public static func uploadCodexRateLimitsIfNewer(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        eventTimestamp: Date,
        syncId: String,
        deviceId: String
    ) {
        guard isReady(syncId: syncId), let group = groupRef(syncId: syncId), let db else { return }
        let ref = group.collection("codexRateLimits").document("latest")
        db.runTransaction({ transaction, errorPointer in
            let existing = try? transaction.getDocument(ref).data(as: CodexRateLimitsDocument.self)
            if let existing, existing.eventTimestamp >= eventTimestamp {
                return nil
            }
            let doc = CodexRateLimitsDocument(deviceId: deviceId, eventTimestamp: eventTimestamp, primary: primary, secondary: secondary)
            guard let data = try? Firestore.Encoder().encode(doc) else { return nil }
            transaction.setData(data, forDocument: ref)
            return nil
        }, completion: { _, error in
            if let error { print("FirestoreSync: rate limit upload failed: \(error)") }
        })
    }

    public static func observeCodexRateLimits(syncId: String, onChange: @escaping (_ primary: CodexRateLimitWindow?, _ secondary: CodexRateLimitWindow?, _ eventTimestamp: Date?) -> Void) -> ListenerRegistration? {
        groupRef(syncId: syncId)?.collection("codexRateLimits").document("latest").addSnapshotListener { snapshot, error in
            guard let snapshot, snapshot.exists, let decoded = try? snapshot.data(as: CodexRateLimitsDocument.self) else {
                if let error { print("FirestoreSync: rate limit listen failed: \(error)") }
                onChange(nil, nil, nil)
                return
            }
            onChange(decoded.primary, decoded.secondary, decoded.eventTimestamp)
        }
    }

    // MARK: - Appearance / display-item settings (opt-in mirroring, not automatic like
    // usage events — a device only applies these when the user turns on "sync with
    // other devices" for it, since look-and-feel is a personal-per-device choice by
    // default).

    public struct AppearanceSettingsDocument: Codable, Equatable, Sendable {
        public let gaugeColorHex: String
        public let codexColorHex: String
        public let ollamaColorHex: String
        public let gaugeUseGradient: Bool
        public let gaugeStyle: String
        public let showClaudeProvider: Bool
        public let showCodexProvider: Bool
        public let showOllamaProvider: Bool
        public let showTimeGauge: Bool
        public let showTokenGauge: Bool
        public let showTodaySummary: Bool
        public let showEstimatedCost: Bool
        public let showModelBreakdown: Bool
        public let showProjectBreakdown: Bool
        public let showHourlyChart: Bool
        public let showLast7Days: Bool

        private enum CodingKeys: String, CodingKey {
            case gaugeColorHex, codexColorHex, ollamaColorHex, gaugeUseGradient, gaugeStyle
            case showClaudeProvider, showCodexProvider, showOllamaProvider
            case showTimeGauge, showTokenGauge, showTodaySummary, showEstimatedCost
            case showModelBreakdown, showProjectBreakdown, showHourlyChart, showLast7Days
        }

        /// Older paired devices wrote settings before Ollama existed. Keep those documents
        /// readable and apply the new provider defaults until the next settings upload.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            gaugeColorHex = try values.decode(String.self, forKey: .gaugeColorHex)
            codexColorHex = try values.decode(String.self, forKey: .codexColorHex)
            ollamaColorHex = try values.decodeIfPresent(String.self, forKey: .ollamaColorHex) ?? "#F97316"
            gaugeUseGradient = try values.decode(Bool.self, forKey: .gaugeUseGradient)
            gaugeStyle = try values.decode(String.self, forKey: .gaugeStyle)
            showClaudeProvider = try values.decode(Bool.self, forKey: .showClaudeProvider)
            showCodexProvider = try values.decode(Bool.self, forKey: .showCodexProvider)
            showOllamaProvider = try values.decodeIfPresent(Bool.self, forKey: .showOllamaProvider) ?? true
            showTimeGauge = try values.decode(Bool.self, forKey: .showTimeGauge)
            showTokenGauge = try values.decode(Bool.self, forKey: .showTokenGauge)
            showTodaySummary = try values.decode(Bool.self, forKey: .showTodaySummary)
            showEstimatedCost = try values.decode(Bool.self, forKey: .showEstimatedCost)
            showModelBreakdown = try values.decode(Bool.self, forKey: .showModelBreakdown)
            showProjectBreakdown = try values.decode(Bool.self, forKey: .showProjectBreakdown)
            showHourlyChart = try values.decode(Bool.self, forKey: .showHourlyChart)
            showLast7Days = try values.decode(Bool.self, forKey: .showLast7Days)
        }

        public init(
            gaugeColorHex: String,
            codexColorHex: String,
            ollamaColorHex: String,
            gaugeUseGradient: Bool,
            gaugeStyle: String,
            showClaudeProvider: Bool,
            showCodexProvider: Bool,
            showOllamaProvider: Bool,
            showTimeGauge: Bool,
            showTokenGauge: Bool,
            showTodaySummary: Bool,
            showEstimatedCost: Bool,
            showModelBreakdown: Bool,
            showProjectBreakdown: Bool,
            showHourlyChart: Bool,
            showLast7Days: Bool
        ) {
            self.gaugeColorHex = gaugeColorHex
            self.codexColorHex = codexColorHex
            self.ollamaColorHex = ollamaColorHex
            self.gaugeUseGradient = gaugeUseGradient
            self.gaugeStyle = gaugeStyle
            self.showClaudeProvider = showClaudeProvider
            self.showCodexProvider = showCodexProvider
            self.showOllamaProvider = showOllamaProvider
            self.showTimeGauge = showTimeGauge
            self.showTokenGauge = showTokenGauge
            self.showTodaySummary = showTodaySummary
            self.showEstimatedCost = showEstimatedCost
            self.showModelBreakdown = showModelBreakdown
            self.showProjectBreakdown = showProjectBreakdown
            self.showHourlyChart = showHourlyChart
            self.showLast7Days = showLast7Days
        }
    }

    public static func uploadAppearanceSettings(_ settings: AppearanceSettingsDocument, syncId: String) {
        guard isReady(syncId: syncId), let group = groupRef(syncId: syncId) else { return }
        let ref = group.collection("settings").document("appearance")
        guard let data = try? Firestore.Encoder().encode(settings) else { return }
        ref.setData(data) { error in
            if let error { print("FirestoreSync: appearance settings upload failed: \(error)") }
        }
    }

    public static func observeAppearanceSettings(syncId: String, onChange: @escaping (AppearanceSettingsDocument?) -> Void) -> ListenerRegistration? {
        groupRef(syncId: syncId)?.collection("settings").document("appearance").addSnapshotListener { snapshot, error in
            guard let snapshot, snapshot.exists, let decoded = try? snapshot.data(as: AppearanceSettingsDocument.self) else {
                if let error { print("FirestoreSync: appearance settings listen failed: \(error)") }
                onChange(nil)
                return
            }
            onChange(decoded)
        }
    }

    // MARK: - Remote notifications (cross-device "ping" — e.g. Mac tells the paired
    // iPhone that Claude/Codex just finished responding). Each ping is its own document
    // rather than one shared "latest" doc so a burst of pings isn't lossy the way a
    // single overwritten field would be; callers filter to documents created after they
    // started listening so relaunching the app never replays old pings as new ones.

    public struct RemoteNotificationDocument: Codable, Sendable {
        public let sourceDeviceId: String
        public let title: String
        public let body: String
        public let createdAt: Date

        public init(sourceDeviceId: String, title: String, body: String, createdAt: Date) {
            self.sourceDeviceId = sourceDeviceId
            self.title = title
            self.body = body
            self.createdAt = createdAt
        }
    }

    public static func sendRemoteNotification(title: String, body: String, syncId: String, deviceId: String) {
        guard isReady(syncId: syncId), let group = groupRef(syncId: syncId) else { return }
        let doc = RemoteNotificationDocument(sourceDeviceId: deviceId, title: title, body: body, createdAt: Date())
        guard let data = try? Firestore.Encoder().encode(doc) else { return }
        group.collection("notifications").document(UUID().uuidString).setData(data) { error in
            if let error { print("FirestoreSync: remote notification send failed: \(error)") }
        }
    }

    /// `onNotification` fires once per new document whose `sourceDeviceId` isn't
    /// `excludingDeviceId` — callers are expected to only start observing once (e.g. at
    /// listener-attach time) and compare `createdAt` against that moment themselves if
    /// they need to ignore backlog; this call does not filter by time on its own since a
    /// caller reattaching mid-session (e.g. after re-pairing) may legitimately want the
    /// most recent one even if it predates *this* attach.
    public static func observeRemoteNotifications(syncId: String, excludingDeviceId: String, onNotification: @escaping (_ id: String, _ title: String, _ body: String, _ createdAt: Date) -> Void) -> ListenerRegistration? {
        groupRef(syncId: syncId)?.collection("notifications").addSnapshotListener { snapshot, error in
            guard let snapshot else {
                if let error { print("FirestoreSync: remote notification listen failed: \(error)") }
                return
            }
            for change in snapshot.documentChanges where change.type == .added {
                guard let decoded = try? change.document.data(as: RemoteNotificationDocument.self),
                      decoded.sourceDeviceId != excludingDeviceId else { continue }
                onNotification(change.document.documentID, decoded.title, decoded.body, decoded.createdAt)
            }
        }
    }

    // MARK: - Helpers

    private static func documentId(deviceId: String, sessionId: String, timestamp: Date) -> String {
        let raw = "\(deviceId)_\(sessionId)_\(Int(timestamp.timeIntervalSince1970 * 1000))"
        return raw.replacingOccurrences(of: "/", with: "_")
    }
}
