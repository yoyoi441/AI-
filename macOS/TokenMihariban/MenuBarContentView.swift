import SwiftUI
import AppKit
import Charts
import ClaudeUsageCore

struct MenuBarContentView: View, LocalizedView {
    @ObservedObject var monitor: UsageMonitor
    @Environment(\.openSettings) private var openSettings

    @AppStorage("showTimeGauge") private var showTimeGauge = true
    @AppStorage("showTokenGauge") private var showTokenGauge = true
    @AppStorage("showTodaySummary") private var showTodaySummary = true
    @AppStorage("showEstimatedCost") private var showEstimatedCost = false
    @AppStorage("showModelBreakdown") private var showModelBreakdown = true
    @AppStorage("showProjectBreakdown") private var showProjectBreakdown = true
    @AppStorage("showHourlyChart") private var showHourlyChart = true
    @AppStorage("showLast7Days") private var showLast7Days = true
    @AppStorage("showClaudeProvider") private var showClaudeProvider = true
    @AppStorage("showCodexProvider") private var showCodexProvider = true
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

    private var dailyWindow: DailyTimeWindow { DailyTimeWindow(startMinute: customWindowStartMinute, endMinute: customWindowEndMinute) }

    private var gaugeColor: Color { Color(hex: monitor.snapshot.appearance.colorHex) ?? .blue }
    private var gaugeUseGradient: Bool { monitor.snapshot.appearance.useGradient }
    private var codexColor: Color { Color(hex: monitor.codexSnapshot.colorHex) ?? .green }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if showClaudeProvider {
                    header("Claude Code", systemImage: "bolt.fill")

                    if showTimeGauge || showTokenGauge {
                        Divider()
                        gaugesSection
                    }

                    if dailyTargetEnabled && claudeDailyTokenTarget > 0 || windowTargetEnabled && claudeWindowTokenTarget > 0 {
                        Divider()
                        alertGaugesSection(
                            dailyTotal: monitor.snapshot.todayTotalTokens,
                            dailyTarget: dailyTargetEnabled ? claudeDailyTokenTarget : 0,
                            windowTotal: monitor.snapshot.hourlyTokensToday.tokensInWindow(dailyWindow),
                            windowTarget: windowTargetEnabled ? claudeWindowTokenTarget : 0,
                            color: gaugeColor
                        )
                    }

                    if showTodaySummary || showEstimatedCost || showModelBreakdown || showProjectBreakdown {
                        Divider()
                        todaySection
                    }

                    if showHourlyChart && !monitor.snapshot.hourlyTokensToday.isEmpty {
                        chartSection(points: monitor.snapshot.hourlyTokensToday, color: gaugeColor)
                    }

                    if showLast7Days {
                        Divider()
                        Text(t("last7DaysFormat", formattedTokens(monitor.snapshot.last7DaysTotalTokens)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showClaudeProvider && showCodexProvider {
                    Divider().padding(.vertical, 4)
                }

                if showCodexProvider {
                    header("Codex", systemImage: "cpu")

                    Divider()
                    codexGaugesSection

                    if dailyTargetEnabled && codexDailyTokenTarget > 0 || windowTargetEnabled && codexWindowTokenTarget > 0 {
                        Divider()
                        alertGaugesSection(
                            dailyTotal: monitor.codexSnapshot.todayTotalTokens,
                            dailyTarget: dailyTargetEnabled ? codexDailyTokenTarget : 0,
                            windowTotal: monitor.codexSnapshot.hourlyTokensToday.tokensInWindow(dailyWindow),
                            windowTarget: windowTargetEnabled ? codexWindowTokenTarget : 0,
                            color: codexColor
                        )
                    }

                    if showTodaySummary || showModelBreakdown || showProjectBreakdown {
                        Divider()
                        codexTodaySection
                    }

                    if showHourlyChart && !monitor.codexSnapshot.hourlyTokensToday.isEmpty {
                        chartSection(points: monitor.codexSnapshot.hourlyTokensToday, color: codexColor)
                    }

                    if showLast7Days {
                        Divider()
                        Text(t("last7DaysFormat", formattedTokens(monitor.codexSnapshot.last7DaysTotalTokens)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                footer
            }
            .padding(16)
        }
        .frame(width: 320, height: 720)
    }

    private func header(_ title: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
            Text("\(title) \(t("usageSuffix"))")
                .font(.headline)
            Spacer()
        }
    }

    private var gaugeStyle: GaugeDisplayStyle { monitor.snapshot.appearance.style }

    private var gaugesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let block = monitor.snapshot.currentBlock {
                if gaugeStyle == .ring {
                    HStack(alignment: .top, spacing: 24) {
                        if showTimeGauge { timeRing(block: block) }
                        if showTokenGauge { tokenRing(block: block) }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if showTimeGauge { timeBar(block: block) }
                        if showTokenGauge { tokenBar(block: block) }
                    }
                }

                if showTokenGauge && monitor.snapshot.referenceTokens.map({ $0 > 0 }) == true {
                    if monitor.snapshot.referenceIsLowConfidence {
                        Text(t("tokenEstimateLowConfidenceNoteFormat", monitor.snapshot.historicalBlockCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(t("tokenEstimateNote"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(t("noActiveBlock"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timeRing(block: SessionBlockSummary) -> some View {
        let fraction = timeFraction(block: block)
        return VStack(spacing: 4) {
            CircularGaugeRing(fraction: fraction, color: gaugeColor, useGradient: gaugeUseGradient, lineWidth: 9) {
                Text(compactRemaining(until: block.end))
                    .font(.system(size: 16, weight: .bold))
            }
            .frame(width: 92, height: 92)
            Text(t("resetIn")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func tokenRing(block: SessionBlockSummary) -> some View {
        Group {
            if let reference = monitor.snapshot.referenceTokens, reference > 0 {
                let fraction = min(1, Double(block.totalTokens) / Double(reference))
                let color = fraction > 0.85 ? Color.red : gaugeColor

                VStack(spacing: 4) {
                    CircularGaugeRing(fraction: fraction, color: color, useGradient: gaugeUseGradient, lineWidth: 9) {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .frame(width: 92, height: 92)
                    Text("\(formattedTokens(block.totalTokens)) / \(formattedTokens(reference))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    Text(formattedTokens(block.totalTokens))
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 92, height: 92)
                    Text(t("tokenTargetUnset"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func timeBar(block: SessionBlockSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t("time")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(compactRemaining(until: block.end)).font(.caption.monospacedDigit())
            }
            GaugeBar(fraction: timeFraction(block: block), color: gaugeColor, useGradient: gaugeUseGradient)
        }
    }

    private func tokenBar(block: SessionBlockSummary) -> some View {
        Group {
            if let reference = monitor.snapshot.referenceTokens, reference > 0 {
                let fraction = min(1, Double(block.totalTokens) / Double(reference))
                let color = fraction > 0.85 ? Color.red : gaugeColor

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(t("tokenLabel")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formattedTokens(block.totalTokens)) / \(formattedTokens(reference))")
                            .font(.caption.monospacedDigit())
                    }
                    GaugeBar(fraction: fraction, color: color, useGradient: gaugeUseGradient)
                }
            } else {
                Text(t("usedTokensNoTarget", formattedTokens(block.totalTokens)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Daily / custom-window alert gauges (user-set targets, shared by
    // Claude and Codex; only shown once a target > 0 is configured in Settings).

    @ViewBuilder
    private func alertGaugesSection(dailyTotal: Int, dailyTarget: Double, windowTotal: Int, windowTarget: Double, color: Color) -> some View {
        if gaugeStyle == .ring {
            HStack(alignment: .top, spacing: 24) {
                if dailyTarget > 0 { alertRing(current: dailyTotal, target: dailyTarget, caption: t("dailyTargetGaugeCaption"), color: color) }
                if windowTarget > 0 { alertRing(current: windowTotal, target: windowTarget, caption: t("customWindowGaugeCaptionFormat", dailyWindow.rangeText()), color: color) }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if dailyTarget > 0 { alertBar(current: dailyTotal, target: dailyTarget, caption: t("dailyTargetGaugeCaption"), color: color) }
                if windowTarget > 0 { alertBar(current: windowTotal, target: windowTarget, caption: t("customWindowGaugeCaptionFormat", dailyWindow.rangeText()), color: color) }
            }
        }
    }

    private func alertRing(current: Int, target: Double, caption: String, color: Color) -> some View {
        let fraction = min(1, Double(current) / target)
        return VStack(spacing: 4) {
            CircularGaugeRing(fraction: fraction, color: fraction >= 1 ? .red : color, useGradient: gaugeUseGradient, lineWidth: 9) {
                Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 16, weight: .bold))
            }
            .frame(width: 92, height: 92)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            Text("\(formattedTokens(current)) / \(formattedTokens(Int(target)))").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func alertBar(current: Int, target: Double, caption: String, color: Color) -> some View {
        let fraction = min(1, Double(current) / target)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(formattedTokens(current)) / \(formattedTokens(Int(target)))").font(.caption.monospacedDigit())
            }
            GaugeBar(fraction: fraction, color: fraction >= 1 ? .red : color, useGradient: gaugeUseGradient)
        }
    }

    private func timeFraction(block: SessionBlockSummary) -> Double {
        let totalDuration = block.end.timeIntervalSince(block.start)
        let remaining = max(0, block.end.timeIntervalSinceNow)
        return totalDuration > 0 ? min(1, max(0, (totalDuration - remaining) / totalDuration)) : 0
    }

    private func compactRemaining(until end: Date) -> String {
        let remaining = max(0, end.timeIntervalSinceNow)
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("today")).font(.subheadline.bold())
            if showTodaySummary {
                Text(t("totalTokensFormat", formattedTokens(monitor.snapshot.todayTotalTokens)))
            }
            if showEstimatedCost {
                Text(t("estimatedCostFormat", formattedCost(monitor.snapshot.todayEstimatedCostUSD)))
                    .foregroundStyle(.secondary)
                if monitor.snapshot.hasUnpricedModelToday {
                    Label(t("unpricedModelWarning"), systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if showModelBreakdown {
                ForEach(monitor.snapshot.todayModelBreakdown) { entry in
                    let total = entry.inputTokens + entry.outputTokens + entry.cacheCreationTokens + entry.cacheReadTokens
                    Text(t("modelBreakdownLineFormat", entry.model, formattedTokens(total)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showProjectBreakdown {
                projectBreakdownList(monitor.snapshot.todayByProject)
            }
        }
    }

    private func projectBreakdownList(_ entries: [ProjectUsageEntry]) -> some View {
        let topEntries = entries.prefix(5)
        return Group {
            if !topEntries.isEmpty {
                Text(t("projectBreakdownHeader"))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(Array(topEntries)) { entry in
                    Text(t("modelBreakdownLineFormat", entry.displayName, formattedTokens(entry.tokens)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if entries.count > topEntries.count {
                    Text(t("moreProjectsFormat", entries.count - topEntries.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chartSection(points: [HourlyUsagePoint], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HourlyChartSection(
                points: points,
                color: color,
                useGradient: gaugeUseGradient,
                title: t("hourlyChartTitle"),
                hourAxisLabel: t("hourLabel"),
                tokenAxisLabel: t("tokenLabel")
            )
            .frame(height: 100)
        }
    }

    // MARK: - Codex

    private var codexGaugesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.codexSnapshot.primaryWindow != nil || monitor.codexSnapshot.secondaryWindow != nil {
                if gaugeStyle == .ring {
                    HStack(alignment: .top, spacing: 24) {
                        if showTimeGauge, let window = monitor.codexSnapshot.primaryWindow {
                            codexRing(window: window, caption: windowLabel(window))
                        }
                        if showTokenGauge, let window = monitor.codexSnapshot.secondaryWindow {
                            codexRing(window: window, caption: windowLabel(window))
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if showTimeGauge, let window = monitor.codexSnapshot.primaryWindow {
                            codexBar(window: window, caption: windowLabel(window))
                        }
                        if showTokenGauge, let window = monitor.codexSnapshot.secondaryWindow {
                            codexBar(window: window, caption: windowLabel(window))
                        }
                    }
                }
                Text(t("codexOfficialNote"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(t("codexNoData"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windowLabel(_ window: CodexRateLimitWindow) -> String {
        if window.windowMinutes >= 1440 {
            return t("perDaysFormat", window.windowMinutes / 1440)
        }
        return t("perHoursFormat", window.windowMinutes / 60)
    }

    private func codexRing(window: CodexRateLimitWindow, caption: String) -> some View {
        let color = window.fraction > 0.85 ? Color.red : codexColor
        return VStack(spacing: 4) {
            CircularGaugeRing(fraction: window.fraction, color: color, useGradient: gaugeUseGradient, lineWidth: 9) {
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 16, weight: .bold))
            }
            .frame(width: 92, height: 92)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            Text(compactRemaining(until: window.resetsAt)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func codexBar(window: CodexRateLimitWindow, caption: String) -> some View {
        let color = window.fraction > 0.85 ? Color.red : codexColor
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% ・ \(compactRemaining(until: window.resetsAt))")
                    .font(.caption.monospacedDigit())
            }
            GaugeBar(fraction: window.fraction, color: color, useGradient: gaugeUseGradient)
        }
    }

    private var codexTodaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("today")).font(.subheadline.bold())
            if showTodaySummary {
                Text(t("totalTokensFormat", formattedTokens(monitor.codexSnapshot.todayTotalTokens)))
            }
            if showModelBreakdown {
                ForEach(monitor.codexSnapshot.todayModelBreakdown) { entry in
                    let total = entry.inputTokens + entry.outputTokens
                    Text(t("modelBreakdownLineFormat", entry.model, formattedTokens(total)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showProjectBreakdown {
                projectBreakdownList(monitor.codexSnapshot.todayByProject)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(t("refresh")) { monitor.refresh() }
            Spacer()
            Button(t("settingsEllipsis")) {
                // LSUIElement (accessory) apps can fail to surface the Settings window
                // reliably; temporarily becoming a regular app guarantees it opens and
                // comes to the front. SettingsView flips this back on close.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button(t("quit")) { NSApplication.shared.terminate(nil) }
        }
    }

    private func formattedTokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func formattedCost(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }
}
