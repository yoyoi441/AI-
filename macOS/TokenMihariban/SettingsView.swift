import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import ClaudeUsageCore
import ClaudeUsageSync

struct SettingsView: View, LocalizedView {
    @ObservedObject var monitor: UsageMonitor
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRaw = AppLanguage.japanese.rawValue
    var lang: AppLanguage { AppLanguagePreference.resolve(from: appLanguageRaw) }

    var body: some View {
        TabView {
            GeneralSettingsTab(monitor: monitor)
                .tabItem { Label(t("generalTab"), systemImage: "power") }
            AppearanceSettingsTab(monitor: monitor)
                .tabItem { Label(t("appearanceTab"), systemImage: "paintpalette") }
            DisplayItemsSettingsTab(monitor: monitor)
                .tabItem { Label(t("displayItemsTab"), systemImage: "list.bullet.rectangle") }
            TokenTargetSettingsTab(monitor: monitor)
                .tabItem { Label(t("tokenTargetTab"), systemImage: "gauge.with.needle") }
            SyncSettingsTab(monitor: monitor)
                .tabItem { Label(t("deviceSyncTab"), systemImage: "arrow.triangle.2.circlepath") }
            ExportSettingsTab(monitor: monitor)
                .tabItem { Label(t("exportTab"), systemImage: "square.and.arrow.up") }
        }
        .frame(width: 460, height: 380)
        .onDisappear {
            // Pair with MenuBarContentView's setActivationPolicy(.regular): once Settings
            // closes, go back to a Dock-less accessory app.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct GeneralSettingsTab: View, LocalizedView {
    @ObservedObject var monitor: UsageMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isCheckingForUpdate = false
    @State private var updateStatus = ""
    @AppStorage("automaticUpdateCheckEnabled") private var automaticUpdateCheckEnabled = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRaw = AppLanguage.japanese.rawValue
    var lang: AppLanguage { AppLanguagePreference.resolve(from: appLanguageRaw) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Label(t("launchAtLogin"), systemImage: "menubar.dock.rectangle")
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
                Text(t("launchAtLoginNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(t("launchHeader"))
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("rescanIntervalFormat", Int(monitor.refreshIntervalSeconds)))
                    Slider(value: $monitor.refreshIntervalSeconds, in: 30...600, step: 30)
                    Text(t("rescanNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(t("rescanHeader"))
            }

            Section {
                Text(t("currentVersionFormat", MacUpdateService.currentVersion))
                    .foregroundStyle(.secondary)
                Toggle(t("automaticUpdateCheck"), isOn: $automaticUpdateCheckEnabled)
                Text(t("automaticUpdateCheckNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(t("checkForUpdates")) {
                    Task { await checkForUpdates() }
                }
                .disabled(isCheckingForUpdate)
                if !updateStatus.isEmpty {
                    Text(updateStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(t("updatesHeader"))
            }

            Section {
                Picker(selection: $appLanguageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                } label: {
                    Text(t("languagePickerLabel"))
                }
                .pickerStyle(.segmented)
                .onChange(of: appLanguageRaw) { _, _ in monitor.refresh() }
            } header: {
                Text(t("languageHeader"))
            }

            Section {
                Toggle(isOn: $notificationsEnabled) {
                    Label(t("notificationsToggle"), systemImage: "bell.badge")
                }
                .onChange(of: notificationsEnabled) { _, newValue in
                    if newValue { UsageNotifier.requestAuthorizationIfNeeded() }
                }
                Text(t("notificationsNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    @MainActor
    private func checkForUpdates() async {
        isCheckingForUpdate = true
        updateStatus = t("checkingForUpdates")
        defer { isCheckingForUpdate = false }
        do {
            guard let release = try await MacUpdateService.checkForUpdate() else {
                updateStatus = t("upToDate")
                return
            }
            let alert = NSAlert()
            alert.messageText = t("updatesHeader")
            alert.informativeText = t("updateAvailableFormat", release.version)
            alert.addButton(withTitle: t("installUpdate"))
            alert.addButton(withTitle: t("cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                updateStatus = ""
                return
            }
            updateStatus = t("downloadingUpdate")
            try await MacUpdateService.downloadAndInstall(release)
        } catch {
            updateStatus = t("updateFailedFormat", error.localizedDescription)
        }
    }
}

private struct AppearanceSettingsTab: View, LocalizedView {
    @ObservedObject var monitor: UsageMonitor
    @AppStorage("gaugeColorHex") private var gaugeColorHex: String = GaugeAppearance.default.colorHex
    @AppStorage("gaugeUseGradient") private var gaugeUseGradient: Bool = GaugeAppearance.default.useGradient
    @AppStorage("gaugeStyle") private var gaugeStyle: GaugeDisplayStyle = GaugeAppearance.default.style
    @AppStorage("codexColorHex") private var codexColorHex: String = CodexSnapshot.empty.colorHex
    @AppStorage("menuBarMetric") private var menuBarMetricRaw = GaugeMetric.timeRemaining.rawValue
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRaw = AppLanguage.japanese.rawValue
    var lang: AppLanguage { AppLanguagePreference.resolve(from: appLanguageRaw) }

    private var gaugeColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: gaugeColorHex) ?? .blue },
            set: { gaugeColorHex = $0.hexString }
        )
    }

    private var codexColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: codexColorHex) ?? .green },
            set: { codexColorHex = $0.hexString }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $gaugeStyle) {
                    ForEach(GaugeDisplayStyle.allCases, id: \.self) { style in
                        Text(style.label(lang)).tag(style)
                    }
                } label: {
                    Label(t("displayStyle"), systemImage: "square.on.circle")
                }
                .pickerStyle(.segmented)
                .onChange(of: gaugeStyle) { _, _ in
                    monitor.refresh()
                    monitor.pushAppearanceSettingsIfPaired()
                }
                Text(t("styleAppliesNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(t("styleHeader"))
            }

            Section {
                ColorPicker(selection: gaugeColorBinding, supportsOpacity: false) {
                    Label(t("claudeColorLabel"), systemImage: "paintpalette")
                }
                .onChange(of: gaugeColorHex) { _, _ in
                    monitor.refresh()
                    monitor.pushAppearanceSettingsIfPaired()
                }

                ColorPicker(selection: codexColorBinding, supportsOpacity: false) {
                    Label(t("codexColorLabel"), systemImage: "paintpalette.fill")
                }
                .onChange(of: codexColorHex) { _, _ in
                    monitor.refresh()
                    monitor.pushAppearanceSettingsIfPaired()
                }

                Toggle(isOn: $gaugeUseGradient) {
                    Label(t("gradientToggle"), systemImage: "square.fill.on.square.fill")
                }
                .onChange(of: gaugeUseGradient) { _, _ in
                    monitor.refresh()
                    monitor.pushAppearanceSettingsIfPaired()
                }
            } header: {
                Text(t("colorHeader"))
            } footer: {
                Text(t("colorFooterNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $menuBarMetricRaw) {
                    ForEach(GaugeMetric.allCases) { metric in
                        Text(metric.label(lang)).tag(metric.rawValue)
                    }
                } label: {
                    Text(t("menuBarMetricPickerLabel"))
                }
                .pickerStyle(.segmented)
                Text(t("menuBarMetricNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(t("menuBarMetricHeader"))
            }

            Section {
                Group {
                    if gaugeStyle == .ring {
                        HStack(spacing: 28) {
                            VStack(spacing: 4) {
                                CircularGaugeRing(fraction: 0.5, color: gaugeColorBinding.wrappedValue, useGradient: gaugeUseGradient, lineWidth: 9) {
                                    Text("2h30m").font(.system(size: 15, weight: .bold))
                                }
                                .frame(width: 88, height: 88)
                                Text(t("resetIn")).font(.caption2).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 4) {
                                CircularGaugeRing(fraction: 0.65, color: gaugeColorBinding.wrappedValue, useGradient: gaugeUseGradient, lineWidth: 9) {
                                    Text("65%").font(.system(size: 15, weight: .bold))
                                }
                                .frame(width: 88, height: 88)
                                Text("650,000 / 1,000,000").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(t("time")).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(t("previewTimeDuration")).font(.caption.monospacedDigit())
                                }
                                GaugeBar(fraction: 0.5, color: gaugeColorBinding.wrappedValue, useGradient: gaugeUseGradient)
                                    .frame(height: 14)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(t("tokenLabel")).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("650,000 / 1,000,000").font(.caption.monospacedDigit())
                                }
                                GaugeBar(fraction: 0.65, color: gaugeColorBinding.wrappedValue, useGradient: gaugeUseGradient)
                                    .frame(height: 14)
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
            } header: {
                Text(t("previewHeader"))
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct DisplayItemsSettingsTab: View, LocalizedView {
    @ObservedObject var monitor: UsageMonitor
    @AppStorage("showClaudeProvider") private var showClaudeProvider = true
    @AppStorage("showCodexProvider") private var showCodexProvider = true
    @AppStorage("showTimeGauge") private var showTimeGauge = true
    @AppStorage("showTokenGauge") private var showTokenGauge = true
    @AppStorage("showTodaySummary") private var showTodaySummary = true
    @AppStorage("showEstimatedCost") private var showEstimatedCost = false
    @AppStorage("showModelBreakdown") private var showModelBreakdown = true
    @AppStorage("showProjectBreakdown") private var showProjectBreakdown = true
    @AppStorage("showHourlyChart") private var showHourlyChart = true
    @AppStorage("showLast7Days") private var showLast7Days = true
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRaw = AppLanguage.japanese.rawValue
    var lang: AppLanguage { AppLanguagePreference.resolve(from: appLanguageRaw) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showClaudeProvider) {
                    Label(t("showClaudeProviderToggle"), systemImage: "bolt.fill")
                }
                .onChange(of: showClaudeProvider) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                Toggle(isOn: $showCodexProvider) {
                    Label(t("showCodexProviderToggle"), systemImage: "cpu")
                }
                .onChange(of: showCodexProvider) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
            } header: {
                Text(t("providersHeader"))
            } footer: {
                Text(t("providersNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $showTimeGauge) {
                    Label(t("itemTimeGauge"), systemImage: "clock")
                }
                .onChange(of: showTimeGauge) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                Toggle(isOn: $showTokenGauge) {
                    Label(t("itemTokenGauge"), systemImage: "gauge.with.needle")
                }
                .onChange(of: showTokenGauge) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                Toggle(isOn: $showTodaySummary) {
                    Label(t("itemTodaySummary"), systemImage: "sum")
                }
                .onChange(of: showTodaySummary) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: $showEstimatedCost) {
                        Label(t("itemEstimatedCost"), systemImage: "dollarsign.circle")
                    }
                    .onChange(of: showEstimatedCost) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                    Text(t("estimatedCostExplainer"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $showModelBreakdown) {
                    Label(t("itemModelBreakdown"), systemImage: "list.bullet")
                }
                .onChange(of: showModelBreakdown) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                Toggle(isOn: $showProjectBreakdown) {
                    Label(t("itemProjectBreakdown"), systemImage: "folder")
                }
                .onChange(of: showProjectBreakdown) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                Toggle(isOn: $showHourlyChart) {
                    Label(t("itemHourlyChart"), systemImage: "chart.bar")
                }
                .onChange(of: showHourlyChart) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
                Toggle(isOn: $showLast7Days) {
                    Label(t("itemLast7Days"), systemImage: "calendar")
                }
                .onChange(of: showLast7Days) { _, _ in monitor.pushAppearanceSettingsIfPaired() }
            } header: {
                Text(t("displayItemsHeaderMac"))
            } footer: {
                Text(t("displayItemsFooterMac"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct SyncSettingsTab: View, LocalizedView {
    @ObservedObject var monitor: UsageMonitor
    @State private var syncId: String? = SyncPairing.syncId
    @State private var enteredCode: String = ""
    @State private var justCopied = false
    @State private var pairingBusy = false
    @State private var pairingStatusKey: String?
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRaw = AppLanguage.japanese.rawValue
    var lang: AppLanguage { AppLanguagePreference.resolve(from: appLanguageRaw) }

    var body: some View {
        Form {
            if !FirestoreSync.isAvailable {
                Section {
                    Label(t("firebaseNotConfigured"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(t("firebaseNotConfiguredNoteMac"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let syncId {
                Section {
                    HStack {
                        Text(SyncPairing.formatted(syncId))
                            .font(.system(.title3, design: .monospaced).bold())
                        Spacer()
                        Button(justCopied ? t("copied") : t("copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SyncPairing.formatted(syncId), forType: .string)
                            justCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
                        }
                    }
                    Text(t("pairingCodeNoteMac"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(t("pairingCodeHeader"))
                }

                Section {
                    Button(t("unpairMac"), role: .destructive) {
                        pairingBusy = true
                        FirestoreSync.unpair(syncId: syncId) {
                            DispatchQueue.main.async {
                                SyncPairing.syncId = nil
                                self.syncId = nil
                                pairingBusy = false
                                monitor.syncPairingChanged()
                            }
                        }
                    }
                    .disabled(pairingBusy)
                }
            } else {
                Section {
                    Button(t("createNewCode")) {
                        let code = SyncPairing.generateNewSyncId()
                        pairingBusy = true
                        pairingStatusKey = "pairingConnecting"
                        FirestoreSync.activatePairing(syncId: code, deviceId: SyncPairing.deviceId, createGroup: true) { result in
                            DispatchQueue.main.async {
                                pairingBusy = false
                                switch result {
                                case .success:
                                    SyncPairing.syncId = code
                                    syncId = code
                                    pairingStatusKey = nil
                                    monitor.syncPairingChanged()
                                case .failure:
                                    pairingStatusKey = "pairingFailed"
                                }
                            }
                        }
                    }
                    .disabled(pairingBusy)
                    Text(t("createNewCodeNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(t("startNewHeader"))
                }

                Section {
                    HStack {
                        TextField(t("codePlaceholderMac"), text: $enteredCode)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(connectWithEnteredCode)
                        Button(t("connect")) { connectWithEnteredCode() }
                            .disabled(pairingBusy || enteredCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(t("enterCodeNoteMac"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(t("joinExistingHeader"))
                }
                if let pairingStatusKey {
                    Section {
                        Text(t(pairingStatusKey))
                            .foregroundStyle(pairingStatusKey == "pairingFailed" || pairingStatusKey == "invalidPairingCode" ? .orange : .secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func connectWithEnteredCode() {
        guard let code = SyncPairing.normalize(enteredCode) else {
            pairingStatusKey = "invalidPairingCode"
            return
        }
        pairingBusy = true
        pairingStatusKey = "pairingConnecting"
        FirestoreSync.activatePairing(syncId: code, deviceId: SyncPairing.deviceId, createGroup: false) { result in
            DispatchQueue.main.async {
                pairingBusy = false
                switch result {
                case .success:
                    SyncPairing.syncId = code
                    syncId = code
                    enteredCode = ""
                    pairingStatusKey = nil
                    monitor.syncPairingChanged()
                case .failure:
                    pairingStatusKey = "pairingFailed"
                }
            }
        }
    }
}

private struct TokenTargetSettingsTab: View, LocalizedView {
    private enum TargetField: Hashable {
        case manualBlock, claudeDaily, codexDaily, claudeWindow, codexWindow
    }

    @ObservedObject var monitor: UsageMonitor
    @AppStorage("manualBlockTokenTarget") private var manualBlockTokenTarget: Double = 0
    @AppStorage("dailyTargetEnabled") private var dailyTargetEnabled = false
    @AppStorage("windowTargetEnabled") private var windowTargetEnabled = false
    @AppStorage("claudeDailyTokenTarget") private var claudeDailyTokenTarget: Double = 0
    @AppStorage("codexDailyTokenTarget") private var codexDailyTokenTarget: Double = 0
    @AppStorage("claudeWindowTokenTarget") private var claudeWindowTokenTarget: Double = 0
    @AppStorage("codexWindowTokenTarget") private var codexWindowTokenTarget: Double = 0
    @AppStorage("customWindowStartMinute") private var customWindowStartMinute: Int = DailyTimeWindow.default.startMinute
    @AppStorage("customWindowEndMinute") private var customWindowEndMinute: Int = DailyTimeWindow.default.endMinute
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRaw = AppLanguage.japanese.rawValue
    var lang: AppLanguage { AppLanguagePreference.resolve(from: appLanguageRaw) }
    // Committing on focus loss (not on every keystroke) so typing a new target — whose
    // in-progress digits are often smaller than the final number — doesn't briefly look
    // "exceeded" and fire a notification before the user has finished entering it.
    @FocusState private var focusedField: TargetField?

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinute: customWindowStartMinute) },
            set: { customWindowStartMinute = Self.minute(from: $0); monitor.refresh() }
        )
    }
    private var endDateBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinute: customWindowEndMinute) },
            set: { customWindowEndMinute = Self.minute(from: $0); monitor.refresh() }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField(t("tokenTargetPlaceholderMac"), value: $manualBlockTokenTarget, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .manualBlock)
                Text(t("tokenTargetNoteMac"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(t("tokenTargetHeaderMac"))
            } footer: {
                Text(t("tokenTargetFooterCodexNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $dailyTargetEnabled) {
                    Text(t("dailyTargetEnabledToggle"))
                }
                if dailyTargetEnabled {
                    TextField(t("claudeDailyTargetPlaceholder"), value: $claudeDailyTokenTarget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .claudeDaily)
                    TextField(t("codexDailyTargetPlaceholder"), value: $codexDailyTokenTarget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .codexDaily)
                    Text(t("dailyTargetNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(t("dailyTargetSectionHeader"))
            }

            Section {
                Toggle(isOn: $windowTargetEnabled) {
                    Text(t("windowTargetEnabledToggle"))
                }
                if windowTargetEnabled {
                    HStack {
                        Text(t("customWindowStartLabel"))
                        DatePicker("", selection: startDateBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Spacer()
                        Text(t("customWindowEndLabel"))
                        DatePicker("", selection: endDateBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    TextField(t("claudeWindowTargetPlaceholder"), value: $claudeWindowTokenTarget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .claudeWindow)
                    TextField(t("codexWindowTargetPlaceholder"), value: $codexWindowTokenTarget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .codexWindow)
                    Text(t("customWindowNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(t("customWindowSectionHeader"))
            }
        }
        .onChange(of: dailyTargetEnabled) { _, _ in monitor.refresh() }
        .onChange(of: windowTargetEnabled) { _, _ in monitor.refresh() }
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue != nil { monitor.refresh() }
        }
        .onDisappear { monitor.refresh() }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private static func date(fromMinute minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = minute / 60
        comps.minute = minute % 60
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func minute(from date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}

private struct ExportSettingsTab: View, LocalizedView {
    @ObservedObject var monitor: UsageMonitor
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var format: ExportFormat = .csv
    @State private var statusMessage: String?
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRaw = AppLanguage.japanese.rawValue
    var lang: AppLanguage { AppLanguagePreference.resolve(from: appLanguageRaw) }

    private enum ExportFormat: String, CaseIterable, Identifiable {
        case csv, json
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                DatePicker(t("exportStartDateLabel"), selection: $startDate, displayedComponents: .date)
                DatePicker(t("exportEndDateLabel"), selection: $endDate, displayedComponents: .date)
                Picker(t("exportFormatLabel"), selection: $format) {
                    Text("CSV").tag(ExportFormat.csv)
                    Text("JSON").tag(ExportFormat.json)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(t("exportHeader"))
            } footer: {
                Text(t("exportNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(t("exportButton")) { exportNow() }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func exportNow() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        // Inclusive of the whole end day, not just up to midnight at its start.
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        let rows = monitor.exportRows(from: start, to: end)

        let dateStamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let panel = NSSavePanel()
        switch format {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "claude-usage-\(dateStamp).csv"
        case .json:
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "claude-usage-\(dateStamp).json"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data: Data?
        switch format {
        case .csv: data = UsageExporter.csv(rows: rows).data(using: .utf8)
        case .json: data = UsageExporter.json(rows: rows)
        }

        guard let data, (try? data.write(to: url)) != nil else {
            statusMessage = t("exportFailed")
            return
        }
        statusMessage = t("exportSucceededFormat", rows.count)
    }
}
