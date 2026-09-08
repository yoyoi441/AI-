import Foundation
import FirebaseCore
import FirebaseAuth
import OSLog
import ClaudeUsageCore

private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Keeps the last successful remote result in memory and advances the next query to
/// the newest timestamp already seen. This avoids downloading the same multi-day
/// history once per minute (and exhausting a shared Firestore project's read quota).
private final class EventPollingState<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private let key: (Event) -> String
    private let timestamp: (Event) -> Date
    private var events: [String: Event]
    private var queryCutoff: Date

    init(initial: [Event], fallbackCutoff: Date, key: @escaping (Event) -> String, timestamp: @escaping (Event) -> Date) {
        self.key = key
        self.timestamp = timestamp
        var cached: [String: Event] = [:]
        for event in initial { cached[key(event)] = event }
        self.events = cached
        self.queryCutoff = initial.map(timestamp).max() ?? fallbackCutoff
    }

    func cutoff() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return queryCutoff
    }

    func merge(_ incoming: [Event], oldestAllowed: Date) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        events = events.filter { timestamp($0.value) >= oldestAllowed }
        for event in incoming { events[key(event)] = event }
        if let newest = incoming.map(timestamp).max(), newest > queryCutoff {
            // Keep equality in the query so events sharing the newest timestamp are
            // not lost; the dictionary above removes the one repeated boundary row.
            queryCutoff = newest
        }
        return events.values.sorted { timestamp($0) < timestamp($1) }
    }
}

/// A small removable polling handle with the same lifecycle semantics the app used for
/// Firestore snapshot listeners. Firestore's REST API has no streaming listener, so the
/// macOS menu-bar app refreshes remote state immediately and once per minute.
public final class ListenerRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    fileprivate init(interval: TimeInterval = 60, action: @escaping () -> Void) {
        action()
        let actionBox = UncheckedBox(action)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { actionBox.value() }
        self.timer = timer
        timer.resume()
    }

    public func remove() {
        lock.lock()
        let current = timer
        timer = nil
        lock.unlock()
        current?.setEventHandler {}
        current?.cancel()
    }

    deinit { remove() }
}

/// Cross-device usage synchronization over Firebase Authentication and the Firestore
/// HTTPS REST API. The REST transport is intentional: the prebuilt gRPC framework used
/// by recent Firebase Apple SDK releases aborts on some macOS installations when its
/// POSIX wakeup-pipe support is unavailable. HTTPS keeps the same Firestore data model
/// and security rules without linking or starting gRPC.
public enum FirestoreSync {
    private static let logger = Logger(subsystem: "com.yoyoi441.TokenMihariban", category: "device-sync")
    private struct Config {
        let projectId: String
        let apiKey: String
    }

    private struct Session {
        let uid: String
        let idToken: String
    }

    private enum SyncError: Error {
        case invalidCode
        case firebaseUnavailable
        case authenticationFailed
        case invalidResponse
        case http(Int, String)
    }

    nonisolated(unsafe) private static var didConfigure = false
    nonisolated(unsafe) private static var readyGroups = Set<String>()
    private static let readyGroupsLock = NSLock()
    nonisolated(unsafe) private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    private static var config: Config? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let settings = NSDictionary(contentsOfFile: path) as? [String: Any],
              let projectId = settings["PROJECT_ID"] as? String,
              let apiKey = settings["API_KEY"] as? String,
              !projectId.isEmpty, projectId != "disabled",
              !apiKey.isEmpty, apiKey != "disabled" else { return nil }
        return Config(projectId: projectId, apiKey: apiKey)
    }

    public static var isAvailable: Bool { config != nil }

    public static func configureIfNeeded() {
        guard isAvailable, !didConfigure else { return }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        didConfigure = true
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

    // MARK: - Pairing and authentication

    public static func activatePairing(
        syncId: String,
        deviceId: String,
        createGroup: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let normalized = SyncPairing.normalize(syncId) else {
            completion(.failure(SyncError.invalidCode))
            return
        }
        withSession { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let session):
                func writeMembership() {
                    var writes = [[String: Any]]()
                    if createGroup {
                        writes.append(write(
                            path: "syncGroups/\(normalized)",
                            fields: [
                                "ownerUid": string(session.uid),
                                "createdAt": timestamp(Date()),
                                "schemaVersion": integer(2)
                            ]
                        ))
                    }
                    writes.append(write(
                        path: "syncGroups/\(normalized)/members/\(session.uid)",
                        fields: memberFields(deviceId: deviceId)
                    ))
                    commit(writes: writes, session: session) { result in
                        switch result {
                        case .success:
                            setReady(true, syncId: normalized)
                            completion(.success(()))
                        case .failure(let error):
                            setReady(false, syncId: normalized)
                            completion(.failure(error))
                        }
                    }
                }

                guard !createGroup else {
                    writeMembership()
                    return
                }
                request(
                    method: "GET",
                    url: documentURL(path: "syncGroups/\(normalized)/members/\(session.uid)"),
                    session: session
                ) { status, object, _ in
                    if status == 200,
                       let fields = (object as? [String: Any])?["fields"] as? [String: Any],
                       stringValue(fields, "deviceId") == deviceId {
                        setReady(true, syncId: normalized)
                        completion(.success(()))
                    } else {
                        writeMembership()
                    }
                }
            }
        }
    }

    public static func unpair(syncId: String, completion: @escaping () -> Void) {
        guard let normalized = SyncPairing.normalize(syncId) else { completion(); return }
        withSession { result in
            guard case .success(let session) = result else {
                setReady(false, syncId: normalized)
                completion()
                return
            }
            request(
                method: "DELETE",
                url: documentURL(path: "syncGroups/\(normalized)/members/\(session.uid)"),
                session: session
            ) { _, _, _ in
                setReady(false, syncId: normalized)
                completion()
            }
        }
    }

    private static func withSession(completion: @escaping (Result<Session, Error>) -> Void) {
        configureIfNeeded()
        guard didConfigure else {
            completion(.failure(SyncError.firebaseUnavailable))
            return
        }

        func obtainToken(for user: User) {
            user.getIDToken { token, error in
                if let error { completion(.failure(error)); return }
                guard let token, !token.isEmpty else {
                    completion(.failure(SyncError.authenticationFailed))
                    return
                }
                completion(.success(Session(uid: user.uid, idToken: token)))
            }
        }

        if let user = Auth.auth().currentUser {
            obtainToken(for: user)
            return
        }
        Auth.auth().signInAnonymously { result, error in
            if let error { completion(.failure(error)); return }
            guard let user = result?.user else {
                completion(.failure(SyncError.authenticationFailed))
                return
            }
            obtainToken(for: user)
        }
    }

    // MARK: - Usage event upload

    public static func uploadClaudeEvents(
        _ events: [UsageEvent], syncId: String, deviceId: String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        upload(
            events.map { event in
                write(
                    path: "syncGroups/\(syncId)/claudeEvents/\(documentId(deviceId: deviceId, sessionId: event.sessionId, timestamp: event.timestamp))",
                    fields: ["deviceId": string(deviceId), "event": map(claudeFields(event))]
                )
            },
            syncId: syncId,
            completion: completion
        )
    }

    public static func uploadCodexEvents(
        _ events: [CodexUsageEvent], syncId: String, deviceId: String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        upload(
            events.map { event in
                write(
                    path: "syncGroups/\(syncId)/codexEvents/\(documentId(deviceId: deviceId, sessionId: event.sessionId, timestamp: event.timestamp))",
                    fields: ["deviceId": string(deviceId), "event": map(codexFields(event))]
                )
            },
            syncId: syncId,
            completion: completion
        )
    }

    public static func uploadOllamaEvents(
        _ events: [OllamaUsageEvent], syncId: String, deviceId: String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        upload(
            events.map { event in
                write(
                    path: "syncGroups/\(syncId)/ollamaEvents/\(documentId(deviceId: deviceId, sessionId: event.requestId, timestamp: event.timestamp))",
                    fields: ["deviceId": string(deviceId), "event": map(ollamaFields(event))]
                )
            },
            syncId: syncId,
            completion: completion
        )
    }

    private static func upload(_ writes: [[String: Any]], syncId: String, completion: @escaping (Bool) -> Void) {
        guard isReady(syncId: syncId), !writes.isEmpty else { completion(false); return }
        withSession { result in
            guard case .success(let session) = result else { completion(false); return }
            commit(writes: Array(writes.prefix(400)), session: session) { result in
                completion((try? result.get()) != nil)
            }
        }
    }

    // MARK: - Usage event polling

    private static var recentEventsCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -9, to: Date()) ?? .distantPast
    }

    public static func observeClaudeEvents(
        syncId: String, excludingDeviceId: String,
        initialEvents: [UsageEvent] = [],
        onChange: @escaping ([UsageEvent]) -> Void
    ) -> ListenerRegistration? {
        guard isReady(syncId: syncId) else { return nil }
        let state = EventPollingState(
            initial: initialEvents,
            fallbackCutoff: recentEventsCutoff,
            key: { "\($0.sessionId)|\($0.timestamp.timeIntervalSince1970)|\($0.projectPath)" },
            timestamp: { $0.timestamp }
        )
        return ListenerRegistration {
            queryEvents(syncId: syncId, collection: "claudeEvents", since: state.cutoff()) { rows in
                let events = rows.compactMap { fields -> UsageEvent? in
                    guard stringValue(fields, "deviceId") != excludingDeviceId,
                          let event = mapFields(fields, "event"),
                          let date = dateValue(event, "timestamp") else { return nil }
                    return UsageEvent(
                        timestamp: date,
                        model: stringValue(event, "model"),
                        inputTokens: intValue(event, "inputTokens"),
                        outputTokens: intValue(event, "outputTokens"),
                        cacheCreationTokens: intValue(event, "cacheCreationTokens"),
                        cacheReadTokens: intValue(event, "cacheReadTokens"),
                        sessionId: stringValue(event, "sessionId"),
                        projectPath: stringValue(event, "projectPath", fallback: "unknown")
                    )
                }
                onChange(state.merge(events, oldestAllowed: recentEventsCutoff))
            }
        }
    }

    public static func observeCodexEvents(
        syncId: String, excludingDeviceId: String,
        initialEvents: [CodexUsageEvent] = [],
        onChange: @escaping ([CodexUsageEvent]) -> Void
    ) -> ListenerRegistration? {
        guard isReady(syncId: syncId) else { return nil }
        let state = EventPollingState(
            initial: initialEvents,
            fallbackCutoff: recentEventsCutoff,
            key: { "\($0.sessionId)|\($0.timestamp.timeIntervalSince1970)|\($0.projectPath)" },
            timestamp: { $0.timestamp }
        )
        return ListenerRegistration {
            queryEvents(syncId: syncId, collection: "codexEvents", since: state.cutoff()) { rows in
                let events = rows.compactMap { fields -> CodexUsageEvent? in
                    guard stringValue(fields, "deviceId") != excludingDeviceId,
                          let event = mapFields(fields, "event"),
                          let date = dateValue(event, "timestamp") else { return nil }
                    return CodexUsageEvent(
                        timestamp: date,
                        model: stringValue(event, "model"),
                        inputTokens: intValue(event, "inputTokens"),
                        cachedInputTokens: intValue(event, "cachedInputTokens"),
                        outputTokens: intValue(event, "outputTokens"),
                        reasoningOutputTokens: intValue(event, "reasoningOutputTokens"),
                        sessionId: stringValue(event, "sessionId"),
                        projectPath: stringValue(event, "projectPath", fallback: "unknown")
                    )
                }
                onChange(state.merge(events, oldestAllowed: recentEventsCutoff))
            }
        }
    }

    public static func observeOllamaEvents(
        syncId: String, excludingDeviceId: String,
        initialEvents: [OllamaUsageEvent] = [],
        onChange: @escaping ([OllamaUsageEvent]) -> Void
    ) -> ListenerRegistration? {
        guard isReady(syncId: syncId) else { return nil }
        let state = EventPollingState(
            initial: initialEvents,
            fallbackCutoff: recentEventsCutoff,
            key: { $0.requestId },
            timestamp: { $0.timestamp }
        )
        return ListenerRegistration {
            queryEvents(syncId: syncId, collection: "ollamaEvents", since: state.cutoff()) { rows in
                let events = rows.compactMap { fields -> OllamaUsageEvent? in
                    guard stringValue(fields, "deviceId") != excludingDeviceId,
                          let event = mapFields(fields, "event"),
                          let date = dateValue(event, "timestamp") else { return nil }
                    return OllamaUsageEvent(
                        timestamp: date,
                        model: stringValue(event, "model", fallback: "unknown"),
                        inputTokens: intValue(event, "inputTokens"),
                        outputTokens: intValue(event, "outputTokens"),
                        totalDurationNanoseconds: Int64(intValue(event, "totalDurationNanoseconds")),
                        source: OllamaUsageSource(rawValue: stringValue(event, "source")) ?? .local,
                        requestId: stringValue(event, "requestId")
                    )
                }
                onChange(state.merge(events, oldestAllowed: recentEventsCutoff))
            }
        }
    }

    private static func queryEvents(
        syncId: String,
        collection: String,
        since: Date,
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": collection]],
                "where": [
                    "fieldFilter": [
                        "field": ["fieldPath": "event.timestamp"],
                        "op": "GREATER_THAN_OR_EQUAL",
                        "value": timestamp(since)
                    ]
                ]
            ]
        ]
        withSession { result in
            guard case .success(let session) = result else { return }
            request(method: "POST", url: runQueryURL(syncId: syncId), session: session, body: body) { status, object, error in
                guard status == 200, let rows = object as? [[String: Any]] else {
                    let detail = object.map { String(describing: $0) }
                        ?? error.map { String(describing: $0) }
                        ?? "unknown error"
                    logger.error("REST query failed for \(collection, privacy: .public) (HTTP \(status)): \(detail, privacy: .public)")
                    return
                }
                let fields = rows.compactMap {
                    (($0["document"] as? [String: Any])?["fields"] as? [String: Any])
                }
                logger.info("REST query fetched \(fields.count) documents from \(collection, privacy: .public)")
                completion(fields)
            }
        }
    }

    // MARK: - Codex rate limits

    public static func uploadCodexRateLimitsIfNewer(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        eventTimestamp: Date,
        syncId: String,
        deviceId: String
    ) {
        guard isReady(syncId: syncId) else { return }
        withSession { result in
            guard case .success(let session) = result else { return }
            let path = "syncGroups/\(syncId)/codexRateLimits/latest"
            request(method: "GET", url: documentURL(path: path), session: session) { status, object, _ in
                if status == 200,
                   let fields = (object as? [String: Any])?["fields"] as? [String: Any],
                   let existing = dateValue(fields, "eventTimestamp"),
                   existing >= eventTimestamp { return }

                var fields: [String: Any] = [
                    "deviceId": string(deviceId),
                    "eventTimestamp": timestamp(eventTimestamp)
                ]
                if let primary { fields["primary"] = map(rateWindowFields(primary)) }
                if let secondary { fields["secondary"] = map(rateWindowFields(secondary)) }
                patchDocument(path: path, fields: fields, session: session) { _ in }
            }
        }
    }

    public static func observeCodexRateLimits(
        syncId: String,
        onChange: @escaping (_ primary: CodexRateLimitWindow?, _ secondary: CodexRateLimitWindow?, _ eventTimestamp: Date?) -> Void
    ) -> ListenerRegistration? {
        guard isReady(syncId: syncId) else { return nil }
        return ListenerRegistration {
            withSession { result in
                guard case .success(let session) = result else { return }
                request(method: "GET", url: documentURL(path: "syncGroups/\(syncId)/codexRateLimits/latest"), session: session) { status, object, _ in
                    guard status == 200,
                          let fields = (object as? [String: Any])?["fields"] as? [String: Any] else {
                        onChange(nil, nil, nil)
                        return
                    }
                    onChange(
                        mapFields(fields, "primary").flatMap(rateWindow),
                        mapFields(fields, "secondary").flatMap(rateWindow),
                        dateValue(fields, "eventTimestamp")
                    )
                }
            }
        }
    }

    // MARK: - Appearance settings

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
        guard isReady(syncId: syncId) else { return }
        withSession { result in
            guard case .success(let session) = result else { return }
            patchDocument(
                path: "syncGroups/\(syncId)/settings/appearance",
                fields: appearanceFields(settings),
                session: session
            ) { _ in }
        }
    }

    public static func observeAppearanceSettings(
        syncId: String,
        onChange: @escaping (AppearanceSettingsDocument?) -> Void
    ) -> ListenerRegistration? {
        guard isReady(syncId: syncId) else { return nil }
        return ListenerRegistration {
            withSession { result in
                guard case .success(let session) = result else { return }
                request(method: "GET", url: documentURL(path: "syncGroups/\(syncId)/settings/appearance"), session: session) { status, object, _ in
                    guard status == 200,
                          let fields = (object as? [String: Any])?["fields"] as? [String: Any] else {
                        onChange(nil)
                        return
                    }
                    onChange(appearance(from: fields))
                }
            }
        }
    }

    // MARK: - Remote notifications

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
        guard isReady(syncId: syncId) else { return }
        withSession { result in
            guard case .success(let session) = result else { return }
            patchDocument(
                path: "syncGroups/\(syncId)/notifications/\(UUID().uuidString)",
                fields: [
                    "sourceDeviceId": string(deviceId),
                    "title": string(title),
                    "body": string(body),
                    "createdAt": timestamp(Date())
                ],
                session: session
            ) { _ in }
        }
    }

    public static func observeRemoteNotifications(
        syncId: String,
        excludingDeviceId: String,
        onNotification: @escaping (_ id: String, _ title: String, _ body: String, _ createdAt: Date) -> Void
    ) -> ListenerRegistration? {
        guard isReady(syncId: syncId) else { return nil }
        let seen = SeenDocuments()
        return ListenerRegistration {
            let body: [String: Any] = ["structuredQuery": ["from": [["collectionId": "notifications"]]]]
            withSession { result in
                guard case .success(let session) = result else { return }
                request(method: "POST", url: runQueryURL(syncId: syncId), session: session, body: body) { status, object, _ in
                    guard status == 200, let rows = object as? [[String: Any]] else { return }
                    for row in rows {
                        guard let document = row["document"] as? [String: Any],
                              let name = document["name"] as? String,
                              let fields = document["fields"] as? [String: Any],
                              stringValue(fields, "sourceDeviceId") != excludingDeviceId,
                              let createdAt = dateValue(fields, "createdAt") else { continue }
                        let id = name.split(separator: "/").last.map(String.init) ?? name
                        guard seen.insert(id) else { continue }
                        onNotification(id, stringValue(fields, "title"), stringValue(fields, "body"), createdAt)
                    }
                }
            }
        }
    }

    private final class SeenDocuments: @unchecked Sendable {
        private let lock = NSLock()
        private var values = Set<String>()
        func insert(_ value: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return values.insert(value).inserted
        }
    }

    // MARK: - REST transport

    private static func request(
        method: String,
        url: URL?,
        session: Session,
        body: [String: Any]? = nil,
        completion: @escaping (_ status: Int, _ object: Any?, _ error: Error?) -> Void
    ) {
        guard let url else { completion(0, nil, SyncError.firebaseUnavailable); return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(session.idToken)", forHTTPHeaderField: "Authorization")
        if let body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                completion(0, nil, error)
                return
            }
        }
        let completionBox = UncheckedBox(completion)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            if let error { completionBox.value(status, object, error); return }
            if !(200...299).contains(status) {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completionBox.value(status, object, SyncError.http(status, text))
                return
            }
            completionBox.value(status, object, nil)
        }.resume()
    }

    private static func commit(
        writes: [[String: Any]],
        session: Session,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        request(method: "POST", url: commitURL(), session: session, body: ["writes": writes]) { _, _, error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    private static func patchDocument(
        path: String,
        fields: [String: Any],
        session: Session,
        completion: @escaping (Bool) -> Void
    ) {
        request(method: "PATCH", url: documentURL(path: path), session: session, body: ["fields": fields]) { status, _, _ in
            completion((200...299).contains(status))
        }
    }

    private static func baseDocumentsURL() -> String? {
        guard let config else { return nil }
        let project = config.projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.projectId
        return "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents"
    }

    private static func url(_ raw: String) -> URL? {
        guard let config else { return nil }
        var components = URLComponents(string: raw)
        components?.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        return components?.url
    }

    private static func documentURL(path: String) -> URL? {
        guard let base = baseDocumentsURL() else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return url("\(base)/\(encoded)")
    }

    private static func commitURL() -> URL? {
        guard let base = baseDocumentsURL() else { return nil }
        return url("\(base):commit")
    }

    private static func runQueryURL(syncId: String) -> URL? {
        guard let base = baseDocumentsURL() else { return nil }
        return url("\(base)/syncGroups/\(syncId):runQuery")
    }

    private static func fullDocumentName(path: String) -> String {
        guard let config else { return path }
        return "projects/\(config.projectId)/databases/(default)/documents/\(path)"
    }

    private static func write(path: String, fields: [String: Any]) -> [String: Any] {
        ["update": ["name": fullDocumentName(path: path), "fields": fields]]
    }

    // MARK: - Firestore value encoding/decoding

    private static func memberFields(deviceId: String) -> [String: Any] {
        [
            "deviceId": string(deviceId),
            "platform": string("macos"),
            "joinedAt": timestamp(Date())
        ]
    }

    private static func claudeFields(_ event: UsageEvent) -> [String: Any] {
        [
            "timestamp": timestamp(event.timestamp),
            "model": string(event.model),
            "inputTokens": integer(event.inputTokens),
            "outputTokens": integer(event.outputTokens),
            "cacheCreationTokens": integer(event.cacheCreationTokens),
            "cacheReadTokens": integer(event.cacheReadTokens),
            "sessionId": string(event.sessionId),
            "projectPath": string(event.projectPath)
        ]
    }

    private static func codexFields(_ event: CodexUsageEvent) -> [String: Any] {
        [
            "timestamp": timestamp(event.timestamp),
            "model": string(event.model),
            "inputTokens": integer(event.inputTokens),
            "cachedInputTokens": integer(event.cachedInputTokens),
            "outputTokens": integer(event.outputTokens),
            "reasoningOutputTokens": integer(event.reasoningOutputTokens),
            "sessionId": string(event.sessionId),
            "projectPath": string(event.projectPath)
        ]
    }

    private static func ollamaFields(_ event: OllamaUsageEvent) -> [String: Any] {
        [
            "timestamp": timestamp(event.timestamp),
            "model": string(event.model),
            "inputTokens": integer(event.inputTokens),
            "outputTokens": integer(event.outputTokens),
            "totalDurationNanoseconds": integer(event.totalDurationNanoseconds),
            "source": string(event.source.rawValue),
            "requestId": string(event.requestId)
        ]
    }

    private static func rateWindowFields(_ window: CodexRateLimitWindow) -> [String: Any] {
        var fields: [String: Any] = [
            "usedPercent": double(window.usedPercent),
            "windowMinutes": integer(window.windowMinutes),
            "resetsAt": timestamp(window.resetsAt)
        ]
        if let planType = window.planType { fields["planType"] = string(planType) }
        return fields
    }

    private static func rateWindow(_ fields: [String: Any]) -> CodexRateLimitWindow? {
        guard let resetsAt = dateValue(fields, "resetsAt") else { return nil }
        return CodexRateLimitWindow(
            usedPercent: doubleValue(fields, "usedPercent"),
            windowMinutes: intValue(fields, "windowMinutes"),
            resetsAt: resetsAt,
            planType: optionalStringValue(fields, "planType")
        )
    }

    private static func appearanceFields(_ value: AppearanceSettingsDocument) -> [String: Any] {
        [
            "gaugeColorHex": string(value.gaugeColorHex),
            "codexColorHex": string(value.codexColorHex),
            "ollamaColorHex": string(value.ollamaColorHex),
            "gaugeUseGradient": boolean(value.gaugeUseGradient),
            "gaugeStyle": string(value.gaugeStyle),
            "showClaudeProvider": boolean(value.showClaudeProvider),
            "showCodexProvider": boolean(value.showCodexProvider),
            "showOllamaProvider": boolean(value.showOllamaProvider),
            "showTimeGauge": boolean(value.showTimeGauge),
            "showTokenGauge": boolean(value.showTokenGauge),
            "showTodaySummary": boolean(value.showTodaySummary),
            "showEstimatedCost": boolean(value.showEstimatedCost),
            "showModelBreakdown": boolean(value.showModelBreakdown),
            "showProjectBreakdown": boolean(value.showProjectBreakdown),
            "showHourlyChart": boolean(value.showHourlyChart),
            "showLast7Days": boolean(value.showLast7Days)
        ]
    }

    private static func appearance(from fields: [String: Any]) -> AppearanceSettingsDocument {
        AppearanceSettingsDocument(
            gaugeColorHex: stringValue(fields, "gaugeColorHex"),
            codexColorHex: stringValue(fields, "codexColorHex"),
            ollamaColorHex: stringValue(fields, "ollamaColorHex", fallback: "#F97316"),
            gaugeUseGradient: boolValue(fields, "gaugeUseGradient"),
            gaugeStyle: stringValue(fields, "gaugeStyle"),
            showClaudeProvider: boolValue(fields, "showClaudeProvider"),
            showCodexProvider: boolValue(fields, "showCodexProvider"),
            showOllamaProvider: boolValue(fields, "showOllamaProvider", fallback: true),
            showTimeGauge: boolValue(fields, "showTimeGauge"),
            showTokenGauge: boolValue(fields, "showTokenGauge"),
            showTodaySummary: boolValue(fields, "showTodaySummary"),
            showEstimatedCost: boolValue(fields, "showEstimatedCost"),
            showModelBreakdown: boolValue(fields, "showModelBreakdown"),
            showProjectBreakdown: boolValue(fields, "showProjectBreakdown"),
            showHourlyChart: boolValue(fields, "showHourlyChart"),
            showLast7Days: boolValue(fields, "showLast7Days")
        )
    }

    private static func string(_ value: String) -> [String: Any] { ["stringValue": value] }
    private static func integer<T: BinaryInteger>(_ value: T) -> [String: Any] { ["integerValue": String(value)] }
    private static func double(_ value: Double) -> [String: Any] { ["doubleValue": value] }
    private static func boolean(_ value: Bool) -> [String: Any] { ["booleanValue": value] }
    private static func timestamp(_ value: Date) -> [String: Any] { ["timestampValue": iso8601WithFractional.string(from: value)] }
    private static func map(_ fields: [String: Any]) -> [String: Any] { ["mapValue": ["fields": fields]] }

    private static func stringValue(_ fields: [String: Any], _ key: String, fallback: String = "") -> String {
        ((fields[key] as? [String: Any])?["stringValue"] as? String) ?? fallback
    }

    private static func optionalStringValue(_ fields: [String: Any], _ key: String) -> String? {
        (fields[key] as? [String: Any])?["stringValue"] as? String
    }

    private static func intValue(_ fields: [String: Any], _ key: String) -> Int {
        guard let raw = (fields[key] as? [String: Any])?["integerValue"] else { return 0 }
        if let string = raw as? String { return Int(string) ?? 0 }
        if let number = raw as? NSNumber { return number.intValue }
        return 0
    }

    private static func doubleValue(_ fields: [String: Any], _ key: String) -> Double {
        guard let value = fields[key] as? [String: Any] else { return 0 }
        if let number = value["doubleValue"] as? NSNumber { return number.doubleValue }
        if let string = value["doubleValue"] as? String { return Double(string) ?? 0 }
        if let integer = value["integerValue"] as? String { return Double(integer) ?? 0 }
        return 0
    }

    private static func boolValue(_ fields: [String: Any], _ key: String, fallback: Bool = false) -> Bool {
        ((fields[key] as? [String: Any])?["booleanValue"] as? Bool) ?? fallback
    }

    private static func dateValue(_ fields: [String: Any], _ key: String) -> Date? {
        guard let raw = (fields[key] as? [String: Any])?["timestampValue"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    private static func mapFields(_ fields: [String: Any], _ key: String) -> [String: Any]? {
        ((fields[key] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any]
    }

    private static func documentId(deviceId: String, sessionId: String, timestamp: Date) -> String {
        let raw = "\(deviceId)_\(sessionId)_\(Int(timestamp.timeIntervalSince1970 * 1000))"
        return raw.replacingOccurrences(of: "/", with: "_")
    }
}
