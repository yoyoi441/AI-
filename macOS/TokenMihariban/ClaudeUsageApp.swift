import SwiftUI
import AppKit
import ClaudeUsageCore

@main
struct TokenMiharibanApp: App {
    @NSApplicationDelegateAdaptor(TokenMiharibanAppDelegate.self) private var appDelegate
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(monitor: monitor)
        } label: {
            MenuBarLabel(snapshot: monitor.snapshot, codexSnapshot: monitor.codexSnapshot, ollamaSnapshot: monitor.ollamaSnapshot)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}

final class TokenMiharibanAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await checkForUpdatesAtLaunch()
        }
    }

    @MainActor
    private func checkForUpdatesAtLaunch() async {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "automaticUpdateCheckEnabled") == nil
            ? true
            : defaults.bool(forKey: "automaticUpdateCheckEnabled")
        guard enabled, let release = try? await MacUpdateService.checkForUpdate() else { return }

        let lang = AppLanguagePreference.resolve(from: defaults.string(forKey: AppLanguagePreference.storageKey))
        let alert = NSAlert()
        alert.messageText = L.string("updatesHeader", lang: lang)
        alert.informativeText = L.string("updateAvailableFormat", lang: lang, args: [release.version])
        alert.addButton(withTitle: L.string("installUpdate", lang: lang))
        alert.addButton(withTitle: L.string("cancel", lang: lang))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try await MacUpdateService.downloadAndInstall(release)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = L.string("updatesHeader", lang: lang)
            errorAlert.informativeText = L.string("updateFailedFormat", lang: lang, args: [error.localizedDescription])
            errorAlert.runModal()
        }
    }
}

/// One provider's worth of status-bar gauge data. Adding a future AI provider to the
/// menu bar icon is just adding one more entry to `MenuBarLabel.specs` below — the
/// rendering code itself doesn't know or care how many providers there are.
private struct ProviderIconSpec {
    let fraction: Double
    let color: Color
    let centerText: String
}

private struct MenuBarLabel: View {
    let snapshot: UsageSnapshot
    let codexSnapshot: CodexSnapshot
    let ollamaSnapshot: OllamaSnapshot
    @AppStorage("menuBarMetric") private var menuBarMetricRaw = GaugeMetric.timeRemaining.rawValue
    @AppStorage("showClaudeProvider") private var showClaudeProvider = true
    @AppStorage("showCodexProvider") private var showCodexProvider = true
    @AppStorage("showOllamaProvider") private var showOllamaProvider = true
    private var metric: GaugeMetric { GaugeMetric(rawValue: menuBarMetricRaw) ?? .timeRemaining }

    private var specs: [ProviderIconSpec] {
        var result: [ProviderIconSpec] = []
        if showClaudeProvider, let block = snapshot.currentBlock {
            let color = Color(hex: snapshot.appearance.colorHex) ?? .blue
            switch metric {
            case .timeRemaining:
                let fraction = timeFraction(block: block)
                result.append(ProviderIconSpec(fraction: fraction, color: color, centerText: "\(Int((fraction * 100).rounded()))"))
            case .tokenUsage:
                if let reference = snapshot.referenceTokens, reference > 0 {
                    let fraction = min(1, Double(block.totalTokens) / Double(reference))
                    result.append(ProviderIconSpec(fraction: fraction, color: color, centerText: "\(Int((fraction * 100).rounded()))"))
                } else {
                    // No token target set to measure usage against — fall back to the
                    // time-based reading rather than showing a meaningless 0%.
                    let fraction = timeFraction(block: block)
                    result.append(ProviderIconSpec(fraction: fraction, color: color, centerText: "\(Int((fraction * 100).rounded()))"))
                }
            }
        }
        if showCodexProvider, let primary = codexSnapshot.primaryWindow {
            let color = Color(hex: codexSnapshot.colorHex) ?? .green
            switch metric {
            case .timeRemaining:
                let fraction = timeFraction(resetsAt: primary.resetsAt, windowMinutes: primary.windowMinutes)
                result.append(ProviderIconSpec(fraction: fraction, color: color, centerText: "\(Int((fraction * 100).rounded()))"))
            case .tokenUsage:
                result.append(ProviderIconSpec(fraction: primary.fraction, color: color, centerText: "\(Int(primary.usedPercent.rounded()))"))
            }
        }
        if showOllamaProvider, ollamaSnapshot.todayTotalTokens > 0 {
            let color = Color(hex: ollamaSnapshot.colorHex) ?? .orange
            if let fraction = ollamaSnapshot.targetFraction {
                result.append(ProviderIconSpec(fraction: fraction, color: color, centerText: "\(Int((fraction * 100).rounded()))"))
            } else {
                result.append(ProviderIconSpec(fraction: 1, color: color, centerText: compactTokens(ollamaSnapshot.todayTotalTokens)))
            }
        }
        return result
    }

    private func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    var body: some View {
        if specs.isEmpty {
            Text("Claude")
        } else {
            // Vector shapes drawn directly as the status item's label don't reliably
            // keep their color in the menu bar (observed rendering as a solid black
            // blob) — rasterizing to a plain bitmap first and showing that as an
            // .original-rendering-mode Image sidesteps whatever that pipeline is doing.
            Image(nsImage: renderedIcon(specs: specs, style: snapshot.appearance.style))
                .renderingMode(.original)
        }
    }

    private func renderedIcon(specs: [ProviderIconSpec], style: GaugeDisplayStyle) -> NSImage {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let textColor: Color = isDark ? .white : .black
        let size: CGFloat = style == .ring ? 20 : 34
        let lineWidth: CGFloat = 3
        // A stroked Circle/Capsule paints half its line width outside the shape's own
        // bounds; without this inset, that overflow gets clipped at the canvas edge
        // (reported as the left/right edges looking slightly cut off).
        let inset = lineWidth / 2 + 0.5
        let spacing: CGFloat = 4

        let content = HStack(spacing: spacing) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                switch style {
                case .ring:
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.35), lineWidth: lineWidth)
                        Circle()
                            .trim(from: 0, to: max(0.02, spec.fraction))
                            .stroke(spec.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(spec.centerText)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(textColor)
                    }
                    .padding(inset)
                    .frame(width: size, height: size)
                case .bar:
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.35))
                        Capsule().fill(spec.color).frame(width: max(3, (size - inset * 2) * spec.fraction))
                    }
                    .frame(height: 9 - inset * 2)
                    .padding(inset)
                    .frame(width: size, height: 9)
                }
            }
        }

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let fallbackWidth = size * CGFloat(specs.count) + spacing * CGFloat(max(0, specs.count - 1))
        let fallbackHeight = style == .ring ? size : 9
        return renderer.nsImage ?? NSImage(size: NSSize(width: fallbackWidth, height: fallbackHeight))
    }

    private func timeFraction(block: SessionBlockSummary) -> Double {
        let totalDuration = block.end.timeIntervalSince(block.start)
        let remaining = max(0, block.end.timeIntervalSinceNow)
        return totalDuration > 0 ? min(1, max(0, (totalDuration - remaining) / totalDuration)) : 0
    }

    /// Codex rate-limit windows don't carry their own start time — only how
    /// long the window is (`windowMinutes`) and when it resets — so elapsed fraction
    /// is derived from those two instead of a stored start date.
    private func timeFraction(resetsAt: Date, windowMinutes: Int) -> Double {
        let totalDuration = Double(windowMinutes) * 60
        let remaining = max(0, resetsAt.timeIntervalSinceNow)
        return totalDuration > 0 ? min(1, max(0, (totalDuration - remaining) / totalDuration)) : 0
    }
}
