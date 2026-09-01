import WidgetKit
import SwiftUI
import ClaudeUsageCore

struct ClaudeUsageWidget: Widget {
    let kind = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude CodeとCodexのトークン使用状況・クールタイムを表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallUsageView(entry: entry)
        case .systemLarge:
            LargeUsageView(entry: entry)
        default:
            MediumUsageView(entry: entry)
        }
    }
}

/// One gauge's worth of already-computed display data, so Claude's (heuristic) and
/// Codex's (official) numbers can share the same rendering code once they reach the
/// widget layer.
private struct GaugeSpec {
    let fraction: Double
    let centerText: String
    let caption: String
    let color: Color
}

private func claudeGaugeSpecs(snapshot: UsageSnapshot, color: Color, lang: AppLanguage) -> [GaugeSpec] {
    guard let block = snapshot.currentBlock else { return [] }
    var specs = [
        GaugeSpec(fraction: timeFraction(block: block), centerText: compactRemaining(until: block.end), caption: L.string("time", lang: lang), color: color)
    ]
    if let reference = snapshot.referenceTokens, reference > 0 {
        let fraction = min(1, Double(block.totalTokens) / Double(reference))
        specs.append(GaugeSpec(
            fraction: fraction,
            centerText: "\(Int((fraction * 100).rounded()))%",
            caption: L.string("tokenLabel", lang: lang),
            color: fraction > 0.85 ? .red : color
        ))
    }
    return specs
}

private func codexGaugeSpecs(snapshot: CodexSnapshot, color: Color, lang: AppLanguage) -> [GaugeSpec] {
    var specs: [GaugeSpec] = []
    if let primary = snapshot.primaryWindow {
        specs.append(GaugeSpec(
            fraction: primary.fraction,
            centerText: "\(Int(primary.usedPercent.rounded()))%",
            caption: windowLabel(primary, lang: lang),
            color: primary.fraction > 0.85 ? .red : color
        ))
    }
    if let secondary = snapshot.secondaryWindow {
        specs.append(GaugeSpec(
            fraction: secondary.fraction,
            centerText: "\(Int(secondary.usedPercent.rounded()))%",
            caption: windowLabel(secondary, lang: lang),
            color: secondary.fraction > 0.85 ? .red : color
        ))
    }
    return specs
}

private func windowLabel(_ window: CodexRateLimitWindow, lang: AppLanguage) -> String {
    window.windowMinutes >= 1440 ? L.string("widgetDaysFormat", lang: lang, args: [window.windowMinutes / 1440]) : "\(window.windowMinutes / 60)h"
}

@MainActor @ViewBuilder
private func gaugeRow(specs: [GaugeSpec], style: GaugeDisplayStyle, useGradient: Bool, ringSize: CGFloat, ringLineWidth: CGFloat = 7, lang: AppLanguage) -> some View {
    if specs.isEmpty {
        Text(L.string("noData", lang: lang)).font(.system(size: 10)).foregroundStyle(.secondary)
    } else if style == .ring {
        HStack(spacing: 10) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                VStack(spacing: 2) {
                    CircularGaugeRing(fraction: spec.fraction, color: spec.color, useGradient: useGradient, lineWidth: ringLineWidth) {
                        Text(spec.centerText).font(.system(size: ringSize > 50 ? 12 : 9, weight: .bold))
                    }
                    .frame(width: ringSize, height: ringSize)
                    Text(spec.caption).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    } else {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(spec.caption).font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Text(spec.centerText).font(.system(size: 10, weight: .semibold))
                    }
                    GaugeBar(fraction: spec.fraction, color: spec.color, useGradient: useGradient)
                }
            }
        }
    }
}

private struct SmallUsageView: View {
    let entry: UsageEntry

    private var gaugeColor: Color { Color(hex: entry.snapshot.appearance.colorHex) ?? .blue }
    private var useGradient: Bool { entry.snapshot.appearance.useGradient }
    private var style: GaugeDisplayStyle { entry.snapshot.appearance.style }
    private var lang: AppLanguage { entry.language }

    var body: some View {
        VStack(spacing: 6) {
            Label("Claude", systemImage: "bolt.fill")
                .font(.caption.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            if let block = entry.snapshot.currentBlock {
                if style == .ring {
                    CircularGaugeRing(fraction: timeFraction(block: block), color: gaugeColor, useGradient: useGradient) {
                        VStack(spacing: 0) {
                            Text(compactRemaining(until: block.end))
                                .font(.system(size: 15, weight: .bold))
                            Text(L.string("remaining", lang: lang))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 72, height: 72)
                } else {
                    Spacer(minLength: 0)
                    Text(compactRemaining(until: block.end))
                        .font(.title2.bold())
                    GaugeBar(fraction: timeFraction(block: block), color: gaugeColor, useGradient: useGradient)
                    Spacer(minLength: 0)
                }
            } else {
                Spacer(minLength: 0)
                Text(L.string("waiting", lang: lang))
                    .font(.title3.bold())
                Spacer(minLength: 0)
            }

            Text(L.string("todayTokFormat", lang: lang, args: [formattedTokens(entry.snapshot.todayTotalTokens)]))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Compact side-by-side Claude / Codex columns — enough room for one gauge row each
/// plus today's total, not the full detail `LargeUsageView` shows.
private struct MediumUsageView: View {
    let entry: UsageEntry

    private var claudeColor: Color { Color(hex: entry.snapshot.appearance.colorHex) ?? .blue }
    private var codexColor: Color { Color(hex: entry.codexSnapshot.colorHex) ?? .green }
    private var useGradient: Bool { entry.snapshot.appearance.useGradient }
    private var style: GaugeDisplayStyle { entry.snapshot.appearance.style }
    private var lang: AppLanguage { entry.language }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Claude", systemImage: "bolt.fill").font(.caption.bold())
                Text("\(formattedTokens(entry.snapshot.todayTotalTokens)) tok").font(.system(size: 10)).foregroundStyle(.secondary)
                gaugeRow(specs: claudeGaugeSpecs(snapshot: entry.snapshot, color: claudeColor, lang: lang), style: style, useGradient: useGradient, ringSize: 44, ringLineWidth: 5, lang: lang)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Label("Codex", systemImage: "cpu").font(.caption.bold())
                Text("\(formattedTokens(entry.codexSnapshot.todayTotalTokens)) tok").font(.system(size: 10)).foregroundStyle(.secondary)
                gaugeRow(specs: codexGaugeSpecs(snapshot: entry.codexSnapshot, color: codexColor, lang: lang), style: style, useGradient: useGradient, ringSize: 44, ringLineWidth: 5, lang: lang)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}

/// Full detail for both providers, stacked — Claude on top, Codex below, each laid
/// out like the single-provider medium widget used to be.
private struct LargeUsageView: View {
    let entry: UsageEntry

    private var claudeColor: Color { Color(hex: entry.snapshot.appearance.colorHex) ?? .blue }
    private var codexColor: Color { Color(hex: entry.codexSnapshot.colorHex) ?? .green }
    private var useGradient: Bool { entry.snapshot.appearance.useGradient }
    private var style: GaugeDisplayStyle { entry.snapshot.appearance.style }
    private var lang: AppLanguage { entry.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerRow(
                title: "Claude Code",
                systemImage: "bolt.fill",
                todayTokens: entry.snapshot.todayTotalTokens,
                costText: L.string("estimatedCostWidgetFormat", lang: lang, args: [entry.snapshot.todayEstimatedCostUSD]),
                specs: claudeGaugeSpecs(snapshot: entry.snapshot, color: claudeColor, lang: lang)
            )
            Divider()
            providerRow(
                title: "Codex",
                systemImage: "cpu",
                todayTokens: entry.codexSnapshot.todayTotalTokens,
                costText: nil,
                specs: codexGaugeSpecs(snapshot: entry.codexSnapshot, color: codexColor, lang: lang)
            )
        }
        .padding()
    }

    private func providerRow(title: String, systemImage: String, todayTokens: Int, costText: String?, specs: [GaugeSpec]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage).font(.caption.bold())
                Text(L.string("totalTokensPlainFormat", lang: lang, args: [formattedTokens(todayTokens)])).font(.title3.bold())
                if let costText {
                    Text(costText).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            gaugeRow(specs: specs, style: style, useGradient: useGradient, ringSize: 56, lang: lang)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

private func formattedTokens(_ count: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
}
