import Foundation
import Combine
import WidgetKit
import OSLog
import ClaudeUsageCore
import ClaudeUsageSync

/// Watches both Claude Code's (`~/.claude/projects`) and Codex CLI's (`~/.codex/sessions`)
/// local logs for new usage events, recomputes both snapshots, and publishes them to the
/// menu bar UI and (via SnapshotStore + the App Group container) the widget extension.
///
/// The two providers are kept as separate pipelines throughout, not merged into one
/// model: Claude's block/limit numbers are heuristic estimates (see
/// `SessionBlockCalculator`), while Codex's come straight from OpenAI's own rate-limit
/// reporting (`payload.rate_limits` in its rollout logs) — conflating the two would
/// make the accurate one look as uncertain as the guessed one.
///
/// Updates are event-driven via `FileSystemWatcher` (near-instant: a refresh fires
/// within about a second of either tool writing new data). `refreshIntervalSeconds`
/// only controls a periodic fallback re-scan, in case a filesystem event is missed.
///
/// File offsets are tracked in memory only, for this process's lifetime: a fresh
/// launch always re-parses full history once (offsets start at 0), and only new
/// lines are re-parsed on each subsequent refresh while the app keeps running.
///
/// If this device is paired to a sync group (`SyncPairing.syncId`) and Firebase is
/// configured (`FirestoreSync.isAvailable`), newly-parsed events are also uploaded to
/// Firestore, and events other devices in the group uploaded are downloaded and folded
/// into the same computation — so the displayed totals/reset time reflect *all* paired
/// devices, not just this one. See `FirestoreSync.swift` for why.
@MainActor
final class UsageMonitor: ObservableObject {
    private let syncLogger = Logger(subsystem: "com.yoyoi441.TokenMihariban", category: "device-sync")
    @Published private(set) var snapshot: UsageSnapshot = SnapshotStore.readSnapshot() ?? .empty
    @Published private(set) var codexSnapshot: CodexSnapshot = SnapshotStore.readCodexSnapshot() ?? .empty
    @Published private(set) var ollamaSnapshot: OllamaSnapshot = .empty
    @Published private(set) var remoteOllamaTodayTokens: Int = 0
    @Published private(set) var ollamaProxyState: OllamaProxyState = .stopped
    @Published var refreshIntervalSeconds: Double = 60 {
        didSet { restartFallbackTimer() }
    }

    private var fallbackTimer: Timer?
    private var watcher: FileSystemWatcher?
    private var codexWatcher: FileSystemWatcher?

    private var allEvents: [UsageEvent] = []
    private var fileOffsets: [String: UInt64] = [:]

    private var allCodexEvents: [CodexUsageEvent] = []
    private var codexFileOffsets: [String: UInt64] = [:]
    // Retained across refreshes: a batch of newly-appended lines won't necessarily
    // include a fresh rate_limits payload, so the last known one carries forward.
    // Rollout files aren't visited in chronological order, so a reading only replaces
    // the current one if its own event timestamp is actually newer.
    private var latestCodexPrimaryWindow: CodexRateLimitWindow?
    private var latestCodexSecondaryWindow: CodexRateLimitWindow?
    private var latestCodexWindowEventTimestamp: Date?
    private var lastCodexRateLimitUploadAttempt: (syncId: String, timestamp: Date)?
    private var codexRateLimitUploadInFlight = false

    private let ollamaStore = OllamaUsageStore()
    private let remoteCacheStore = RemoteUsageCacheStore()
    private var ollamaProxy: OllamaProxyService?
    private var allOllamaEvents: [OllamaUsageEvent] = []

    // Events other devices in the same sync group have uploaded (never includes this
    // device's own events — those are already in allEvents/allCodexEvents from the local
    // parse). Combined with the local pool at compute time so every device shows the
    // same account-wide total.
    private var remoteClaudeEvents: [UsageEvent] = []
    private var remoteCodexEvents: [CodexUsageEvent] = []
    private var remoteOllamaEvents: [OllamaUsageEvent] = []
    private var claudeListener: ListenerRegistration?
    private var codexEventsListener: ListenerRegistration?
    private var ollamaEventsListener: ListenerRegistration?
    private var codexRateLimitsListener: ListenerRegistration?
    private var cloudSyncActivationInFlight = false
    private var cloudUploadsInFlight = Set<String>()

    private let projectsDirectory: URL
    private let codexSessionsDirectory: URL
    private let deviceId = SyncPairing.deviceId

    init() {
        projectsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        codexSessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        allOllamaEvents = ollamaStore.load()
        if let syncId = SyncPairing.syncId,
           let cache = remoteCacheStore.load(syncId: syncId) {
            remoteClaudeEvents = cache.claudeEvents
            remoteCodexEvents = cache.codexEvents
            remoteOllamaEvents = cache.ollamaEvents
        }

        FirestoreSync.configureIfNeeded()

        let notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "notificationsEnabled")
        if notificationsEnabled {
            UsageNotifier.requestAuthorizationIfNeeded()
        }

        // A first launch can have gigabytes of Claude/Codex history to parse. Running
        // that work synchronously from init blocks SwiftUI before MenuBarExtra has a
        // chance to install its status item, which makes the app look as though it
        // never launched. Let the first run-loop turn create the menu-bar UI, then do
        // the initial scan. Subsequent updates remain event-driven as before.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
        restartFallbackTimer()
        watcher = FileSystemWatcher(rootDirectory: projectsDirectory) { [weak self] in
            Task { @MainActor in self?.scheduleDebouncedRefresh() }
        }
        codexWatcher = FileSystemWatcher(rootDirectory: codexSessionsDirectory) { [weak self] in
            Task { @MainActor in self?.scheduleDebouncedRefresh() }
        }
        let ollamaEnabled = UserDefaults.standard.object(forKey: "ollamaMonitoringEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "ollamaMonitoringEnabled")
        if ollamaEnabled { startOllamaMonitoring() }
        startCloudSyncIfPaired()
    }

    var ollamaLocalProxyURL: String { "http://127.0.0.1:\(OllamaProxyService.localPort)" }
    var ollamaCloudProxyURL: String { "http://127.0.0.1:\(OllamaProxyService.cloudPort)" }

    func setOllamaMonitoringEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "ollamaMonitoringEnabled")
        if enabled { startOllamaMonitoring() }
        else {
            ollamaProxy?.stop()
            ollamaProxy = nil
            ollamaProxyState = .stopped
        }
    }

    private func startOllamaMonitoring() {
        guard ollamaProxy == nil else { return }
        let proxy = OllamaProxyService(
            eventHandler: { [weak self] event in
                Task { @MainActor in self?.recordOllamaUsage(event) }
            },
            stateHandler: { [weak self] state in
                Task { @MainActor in self?.ollamaProxyState = state }
            }
        )
        ollamaProxy = proxy
        proxy.start()
    }

    private func recordOllamaUsage(_ event: OllamaUsageEvent) {
        guard !allOllamaEvents.contains(where: { $0.requestId == event.requestId }) else { return }
        allOllamaEvents.append(event)
        ollamaStore.append(event)
        refreshOllama()
        checkUsageAlerts()
    }

    private var refreshDebounceWorkItem: DispatchWorkItem?

    /// Claude Code (and Codex) can append to their log files many times per second while
    /// actively streaming a response — each write fires a separate `FileSystemWatcher`
    /// event. Without coalescing, every one of those would trigger a full `refresh()`,
    /// which re-sorts and re-aggregates the *entire* event history (see
    /// `SessionBlockCalculator.computeBlocks`); back-to-back full recomputes during an
    /// active session were observed driving the app's memory well past what a menu bar
    /// utility should ever need. Collapsing a burst of writes into a single refresh,
    /// fired once activity has been quiet for a moment, keeps the recompute rate sane
    /// without meaningfully delaying when new usage shows up on screen.
    private func scheduleDebouncedRefresh() {
        refreshDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refreshDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    /// Raw per-event rows for the Settings export tab, covering full history (not just
    /// what's shown in the UI, which only ever surfaces today/7-day rollups) across
    /// every paired device — same `local + remote` combination the on-screen totals use,
    /// so the export matches what the app displays rather than just this Mac's share of
    /// it. `allEvents`/`allCodexEvents` never drop old entries once parsed, so any past
    /// date range is available without re-reading log files.
    func exportRows(from start: Date, to end: Date) -> [UsageExportRow] {
        UsageExporter.rows(
            claudeEvents: allEvents + remoteClaudeEvents,
            codexEvents: allCodexEvents + remoteCodexEvents,
            ollamaEvents: allOllamaEvents + remoteOllamaEvents,
            from: start,
            to: end
        )
    }

    /// Call after the user sets up or enters a pairing code in Settings, so listeners
    /// start without needing to relaunch the app.
    func syncPairingChanged() {
        claudeListener?.remove()
        codexEventsListener?.remove()
        ollamaEventsListener?.remove()
        codexRateLimitsListener?.remove()
        remoteClaudeEvents = []
        remoteCodexEvents = []
        remoteOllamaEvents = []
        remoteOllamaTodayTokens = 0
        remoteCacheStore.clear()
        cloudSyncActivationInFlight = false
        lastCodexRateLimitUploadAttempt = nil
        codexRateLimitUploadInFlight = false
        startCloudSyncIfPaired()
        refresh()
    }

    private func startCloudSyncIfPaired() {
        guard FirestoreSync.isAvailable else {
            syncLogger.error("Firebase configuration is unavailable")
            return
        }
        guard let syncId = SyncPairing.syncId else { return }
        guard !FirestoreSync.isReady(syncId: syncId), !cloudSyncActivationInFlight else { return }

        syncLogger.info("Activating device sync for group \(syncId, privacy: .private(mask: .hash))")
        cloudSyncActivationInFlight = true
        FirestoreSync.activatePairing(syncId: syncId, deviceId: deviceId, createGroup: false) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.cloudSyncActivationInFlight = false
                guard SyncPairing.syncId == syncId else { return }
                guard case .success = result else {
                    if case .failure(let error) = result {
                        self.syncLogger.error("Device sync activation failed: \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
                self.syncLogger.info("Device sync is ready")
                self.attachCloudSyncListeners(syncId: syncId)
                // Successful activation immediately retries all locally retained
                // events. If startup was temporarily offline, the fallback refresh
                // calls startCloudSyncIfPaired() again on the next interval.
                self.refresh()
            }
        }
    }

    private func attachCloudSyncListeners(syncId: String) {
        claudeListener?.remove()
        codexEventsListener?.remove()
        ollamaEventsListener?.remove()
        codexRateLimitsListener?.remove()

        claudeListener = FirestoreSync.observeClaudeEvents(
            syncId: syncId,
            excludingDeviceId: deviceId,
            initialEvents: remoteClaudeEvents
        ) { [weak self] events in
            Task { @MainActor in
                guard let self else { return }
                self.remoteClaudeEvents = events
                self.saveRemoteCache(syncId: syncId)
                self.refreshClaude()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        codexEventsListener = FirestoreSync.observeCodexEvents(
            syncId: syncId,
            excludingDeviceId: deviceId,
            initialEvents: remoteCodexEvents
        ) { [weak self] events in
            Task { @MainActor in
                guard let self else { return }
                self.remoteCodexEvents = events
                self.saveRemoteCache(syncId: syncId)
                self.refreshCodex()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        ollamaEventsListener = FirestoreSync.observeOllamaEvents(
            syncId: syncId,
            excludingDeviceId: deviceId,
            initialEvents: remoteOllamaEvents
        ) { [weak self] events in
            Task { @MainActor in
                guard let self else { return }
                self.remoteOllamaEvents = events
                self.saveRemoteCache(syncId: syncId)
                self.refreshOllama()
                self.syncLogger.info("Received \(events.count) remote Ollama events (today: \(self.remoteOllamaTodayTokens) tokens)")
            }
        }
        codexRateLimitsListener = FirestoreSync.observeCodexRateLimits(syncId: syncId) { [weak self] primary, secondary, eventTimestamp in
            Task { @MainActor in
                guard let self, let eventTimestamp else { return }
                if self.latestCodexWindowEventTimestamp == nil || eventTimestamp > self.latestCodexWindowEventTimestamp! {
                    self.latestCodexWindowEventTimestamp = eventTimestamp
                    self.latestCodexPrimaryWindow = primary
                    self.latestCodexSecondaryWindow = secondary
                    self.refreshCodex()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }

        // So a freshly-paired device sees this Mac's current look-and-feel right away,
        // not only after the next time a setting happens to change.
        pushAppearanceSettingsIfPaired()
    }

    private func saveRemoteCache(syncId: String) {
        guard SyncPairing.syncId == syncId else { return }
        remoteCacheStore.save(RemoteUsageCache(
            syncId: syncId,
            claudeEvents: remoteClaudeEvents,
            codexEvents: remoteCodexEvents,
            ollamaEvents: remoteOllamaEvents
        ))
    }

    /// Mac is treated as the source of truth for appearance/display-item settings:
    /// it always shares its current values (regardless of any "sync with Mac" toggle,
    /// which only exists on the receiving/mirroring side, e.g. iPhone).
    func pushAppearanceSettingsIfPaired() {
        guard FirestoreSync.isAvailable, let syncId = SyncPairing.syncId else { return }
        let defaults = UserDefaults.standard
        func flag(_ key: String, default defaultValue: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
        }
        let doc = FirestoreSync.AppearanceSettingsDocument(
            gaugeColorHex: defaults.string(forKey: "gaugeColorHex") ?? GaugeAppearance.default.colorHex,
            codexColorHex: defaults.string(forKey: "codexColorHex") ?? CodexSnapshot.empty.colorHex,
            ollamaColorHex: defaults.string(forKey: "ollamaColorHex") ?? OllamaSnapshot.empty.colorHex,
            gaugeUseGradient: flag("gaugeUseGradient", default: GaugeAppearance.default.useGradient),
            gaugeStyle: defaults.string(forKey: "gaugeStyle") ?? GaugeAppearance.default.style.rawValue,
            showClaudeProvider: flag("showClaudeProvider", default: true),
            showCodexProvider: flag("showCodexProvider", default: true),
            showOllamaProvider: flag("showOllamaProvider", default: true),
            showTimeGauge: flag("showTimeGauge", default: true),
            showTokenGauge: flag("showTokenGauge", default: true),
            showTodaySummary: flag("showTodaySummary", default: true),
            showEstimatedCost: flag("showEstimatedCost", default: false),
            showModelBreakdown: flag("showModelBreakdown", default: true),
            showProjectBreakdown: flag("showProjectBreakdown", default: true),
            showHourlyChart: flag("showHourlyChart", default: true),
            showLast7Days: flag("showLast7Days", default: true)
        )
        FirestoreSync.uploadAppearanceSettings(doc, syncId: syncId)
    }

    func restartFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        startCloudSyncIfPaired()
        refreshClaude()
        refreshCodex()
        refreshOllama()
        checkUsageAlerts()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Fires a local notification (once per day, per provider, per gauge type) when a
    /// user-set daily or custom-window token target is exceeded. Targets default to 0
    /// (disabled) so this is a no-op until the user sets one in Settings.
    private func checkUsageAlerts() {
        let defaults = UserDefaults.standard
        let notificationsEnabled = defaults.object(forKey: "notificationsEnabled") == nil
            ? true
            : defaults.bool(forKey: "notificationsEnabled")
        guard notificationsEnabled else { return }

        let window = DailyTimeWindow(
            startMinute: defaults.object(forKey: "customWindowStartMinute") as? Int ?? DailyTimeWindow.default.startMinute,
            endMinute: defaults.object(forKey: "customWindowEndMinute") as? Int ?? DailyTimeWindow.default.endMinute
        )
        let lang = AppLanguagePreference.resolve(from: defaults.string(forKey: AppLanguagePreference.storageKey))
        let dateKey = todayDateKey()

        if defaults.bool(forKey: "dailyTargetEnabled") {
            checkTarget(current: snapshot.todayTotalTokens, target: defaults.double(forKey: "claudeDailyTokenTarget"), providerName: "Claude Code", kind: "daily", dateKey: dateKey, lang: lang)
            checkTarget(current: codexSnapshot.todayTotalTokens, target: defaults.double(forKey: "codexDailyTokenTarget"), providerName: "Codex", kind: "daily", dateKey: dateKey, lang: lang)
            checkTarget(current: ollamaSnapshot.todayTotalTokens, target: defaults.double(forKey: "ollamaDailyTokenTarget"), providerName: "Ollama", kind: "daily", dateKey: dateKey, lang: lang)
        }
        if defaults.bool(forKey: "windowTargetEnabled") {
            checkTarget(current: snapshot.hourlyTokensToday.tokensInWindow(window), target: defaults.double(forKey: "claudeWindowTokenTarget"), providerName: "Claude Code", kind: "window", dateKey: dateKey, lang: lang)
            checkTarget(current: codexSnapshot.hourlyTokensToday.tokensInWindow(window), target: defaults.double(forKey: "codexWindowTokenTarget"), providerName: "Codex", kind: "window", dateKey: dateKey, lang: lang)
        }
        if let block = snapshot.currentBlock, let target = snapshot.referenceTokens {
            checkBlockPaceAlert(block: block, target: target, lang: lang)
        }
    }

    private func checkTarget(current: Int, target: Double, providerName: String, kind: String, dateKey: String, lang: AppLanguage) {
        guard target > 0, Double(current) > target else { return }
        UsageNotifier.notifyOnce(
            dedupeKey: "mac_\(kind)_\(providerName)_\(dateKey)",
            title: L.string("notificationExceededTitleFormat", lang: lang, args: [providerName]),
            body: L.string("notificationExceededBodyFormat", lang: lang, args: [providerName, formattedNumber(current), formattedNumber(Int(target))])
        )
    }

    /// One-time-per-block heads-up: at the current block's observed pace, its token
    /// target will be reached soon (see `PaceAlertEvaluator.warnWithinMinutes`) — unlike
    /// `checkTarget`, which only fires after a target is already exceeded, this is meant
    /// to give the user time to react before that happens.
    private func checkBlockPaceAlert(block: SessionBlockSummary, target: Int, lang: AppLanguage) {
        guard let minutesUntil = PaceAlertEvaluator.minutesUntilTargetReached(block: block, target: target),
              minutesUntil <= PaceAlertEvaluator.warnWithinMinutes else { return }
        UsageNotifier.notifyOnce(
            dedupeKey: "mac_pace_claude_\(Int(block.start.timeIntervalSince1970))",
            title: L.string("notificationPaceWarningTitleFormat", lang: lang, args: ["Claude Code"]),
            body: L.string("notificationPaceWarningBodyFormat", lang: lang, args: [Int(minutesUntil.rounded()), formattedNumber(target)])
        )
    }

    private func todayDateKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func formattedNumber(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func refreshClaude() {
        var newEvents: [UsageEvent] = []

        for url in findLogFiles(in: projectsDirectory, extension: "jsonl") {
            let key = url.path
            let offset = fileOffsets[key] ?? 0
            guard let result = try? JSONLParser.parseFile(at: url, fromByteOffset: offset) else { continue }
            fileOffsets[key] = result.newOffset
            newEvents.append(contentsOf: result.events)
        }

        if !newEvents.isEmpty {
            allEvents.append(contentsOf: newEvents)
        }
        // Checked every refresh (not just when newEvents is non-empty) against the full
        // local pool, not just this cycle's increment: the per-syncId watermark is the
        // only thing that decides what's already uploaded, so switching pairing codes
        // (a fresh watermark) correctly re-uploads full history without needing a relaunch.
        uploadNewEventsToCloud(allEvents, watermarkKeyPrefix: "lastUploadedClaudeEventAt", timestamp: \.timestamp) { events, syncId, deviceId, completion in
            FirestoreSync.uploadClaudeEvents(events, syncId: syncId, deviceId: deviceId, completion: completion)
        }

        let defaults = UserDefaults.standard
        let manualTarget = defaults.double(forKey: "manualBlockTokenTarget")
        let colorHex = defaults.string(forKey: "gaugeColorHex") ?? GaugeAppearance.default.colorHex
        // Bool defaults to false when unset; treat "never set" as the gradient default (on).
        let useGradient = defaults.object(forKey: "gaugeUseGradient") == nil
            ? GaugeAppearance.default.useGradient
            : defaults.bool(forKey: "gaugeUseGradient")
        let style = defaults.string(forKey: "gaugeStyle").flatMap(GaugeDisplayStyle.init(rawValue:)) ?? GaugeAppearance.default.style

        let computed = SnapshotComputer.computeSnapshot(
            from: allEvents + remoteClaudeEvents,
            manualBlockTokenTarget: manualTarget,
            appearance: GaugeAppearance(colorHex: colorHex, useGradient: useGradient, style: style)
        )
        snapshot = computed
        try? SnapshotStore.writeSnapshot(computed)
        // Widget process reads this from the App Group container (see SnapshotStore) —
        // there's no UserDefaults suite shared between app and extension here.
        try? SnapshotStore.writeLanguage(AppLanguagePreference.resolve(from: defaults.string(forKey: AppLanguagePreference.storageKey)))
    }

    /// Uploads only events newer than the last successful upload (persisted across
    /// restarts), so a fresh launch's full-history reparse doesn't re-upload years of
    /// events to Firestore every time the app starts. The watermark is namespaced by
    /// sync ID: switching to a different (or new) pairing code always starts with no
    /// watermark for that code, so the full local pool re-uploads once instead of
    /// silently appearing incomplete on other devices in the new group.
    private func uploadNewEventsToCloud<Event>(
        _ events: [Event],
        watermarkKeyPrefix: String,
        timestamp: (Event) -> Date,
        upload: ([Event], String, String, @escaping (Bool) -> Void) -> Void
    ) {
        guard FirestoreSync.isAvailable, let syncId = SyncPairing.syncId, FirestoreSync.isReady(syncId: syncId) else { return }
        let watermarkKey = "\(watermarkKeyPrefix)_\(syncId)"
        let watermark = UserDefaults.standard.object(forKey: watermarkKey) as? Double
        let recentFloor = Date().addingTimeInterval(-9 * 24 * 60 * 60).timeIntervalSince1970
        let effectiveFloor = max(recentFloor, watermark ?? recentFloor)
        let toUpload = Array(events
            .filter { timestamp($0).timeIntervalSince1970 > effectiveFloor }
            .sorted { timestamp($0) < timestamp($1) }
            .prefix(400))
        guard !toUpload.isEmpty else { return }
        guard let newest = toUpload.map({ timestamp($0) }).max() else { return }
        guard !cloudUploadsInFlight.contains(watermarkKey) else { return }
        cloudUploadsInFlight.insert(watermarkKey)
        syncLogger.info("Uploading \(toUpload.count) events for \(watermarkKeyPrefix, privacy: .public)")
        upload(toUpload, syncId, deviceId) { succeeded in
            DispatchQueue.main.async {
                self.cloudUploadsInFlight.remove(watermarkKey)
                guard succeeded else {
                    self.syncLogger.error("Upload failed for \(watermarkKeyPrefix, privacy: .public)")
                    return
                }
                self.syncLogger.info("Upload completed for \(watermarkKeyPrefix, privacy: .public)")
                UserDefaults.standard.set(newest.timeIntervalSince1970, forKey: watermarkKey)
            }
        }
    }

    private func refreshCodex() {
        var newEvents: [CodexUsageEvent] = []

        for url in findLogFiles(in: codexSessionsDirectory, extension: "jsonl") {
            guard url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let key = url.path
            let offset = codexFileOffsets[key] ?? 0
            let sessionId = url.deletingPathExtension().lastPathComponent
            guard let result = try? CodexJSONLParser.parseFile(at: url, sessionId: sessionId, fromByteOffset: offset) else { continue }
            codexFileOffsets[key] = result.newOffset
            newEvents.append(contentsOf: result.events)

            if let eventTimestamp = result.latestWindowEventTimestamp,
               latestCodexWindowEventTimestamp == nil || eventTimestamp > latestCodexWindowEventTimestamp! {
                latestCodexWindowEventTimestamp = eventTimestamp
                if let primary = result.latestPrimaryWindow { latestCodexPrimaryWindow = primary }
                if let secondary = result.latestSecondaryWindow { latestCodexSecondaryWindow = secondary }
            }
        }

        if !newEvents.isEmpty {
            allCodexEvents.append(contentsOf: newEvents)
        }
        uploadNewEventsToCloud(allCodexEvents, watermarkKeyPrefix: "lastUploadedCodexEventAt", timestamp: \.timestamp) { events, syncId, deviceId, completion in
            FirestoreSync.uploadCodexEvents(events, syncId: syncId, deviceId: deviceId, completion: completion)
        }

        // Relay this device's freshest known rate-limit reading to the group on every
        // refresh, not just when a new one was parsed this cycle — otherwise a device
        // that already knew its latest reading before pairing (or before switching to
        // a different pairing code) would never push it to a freshly-connected group.
        // The Firestore side only overwrites if this is genuinely newer than what's
        // already there, so redundant calls are harmless.
        if FirestoreSync.isAvailable, let syncId = SyncPairing.syncId, let eventTimestamp = latestCodexWindowEventTimestamp {
            let previous = lastCodexRateLimitUploadAttempt
            if !codexRateLimitUploadInFlight,
               previous?.syncId != syncId || previous?.timestamp != eventTimestamp {
                codexRateLimitUploadInFlight = true
                FirestoreSync.uploadCodexRateLimitsIfNewer(
                    primary: latestCodexPrimaryWindow,
                    secondary: latestCodexSecondaryWindow,
                    eventTimestamp: eventTimestamp,
                    syncId: syncId,
                    deviceId: deviceId
                ) { succeeded in
                    DispatchQueue.main.async {
                        self.codexRateLimitUploadInFlight = false
                        if succeeded {
                            self.lastCodexRateLimitUploadAttempt = (syncId, eventTimestamp)
                        }
                    }
                }
            }
        }

        let colorHex = UserDefaults.standard.string(forKey: "codexColorHex") ?? CodexSnapshot.empty.colorHex

        let computed = SnapshotComputer.computeCodexSnapshot(
            from: allCodexEvents + remoteCodexEvents,
            primaryWindow: latestCodexPrimaryWindow,
            secondaryWindow: latestCodexSecondaryWindow,
            colorHex: colorHex
        )
        codexSnapshot = computed
        try? SnapshotStore.writeCodexSnapshot(computed)
    }

    private func refreshOllama() {
        let defaults = UserDefaults.standard
        let dailyTarget = defaults.bool(forKey: "dailyTargetEnabled")
            ? defaults.double(forKey: "ollamaDailyTokenTarget")
            : 0
        uploadNewEventsToCloud(allOllamaEvents, watermarkKeyPrefix: "lastUploadedOllamaEventAt", timestamp: \.timestamp) { events, syncId, deviceId, completion in
            FirestoreSync.uploadOllamaEvents(events, syncId: syncId, deviceId: deviceId, completion: completion)
        }
        ollamaSnapshot = OllamaUsageComputer.compute(
            events: allOllamaEvents + remoteOllamaEvents,
            dailyTokenTarget: dailyTarget,
            colorHex: defaults.string(forKey: "ollamaColorHex") ?? OllamaSnapshot.empty.colorHex
        )
        remoteOllamaTodayTokens = OllamaUsageComputer.compute(
            events: remoteOllamaEvents,
            dailyTokenTarget: 0,
            colorHex: defaults.string(forKey: "ollamaColorHex") ?? OllamaSnapshot.empty.colorHex
        ).todayTotalTokens
    }

    private func findLogFiles(in directory: URL, extension fileExtension: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == fileExtension }
    }

}
