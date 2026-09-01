import SwiftUI
import Charts

/// The "today's hourly usage" bar chart, with a press-and-hold callout showing the
/// exact hour + token count under the finger/cursor. The callout disappears the
/// moment the press ends — this isn't a persistent "tap to select" state, it only
/// exists to answer "what's this bar?" while actively touching it.
///
/// The callout is drawn as a floating `.chartOverlay` layer positioned by coordinate,
/// deliberately not a mark `.annotation(...)` — an annotation participates in the
/// chart's own layout pass and reserves space for itself, which made the whole chart
/// visibly shrink/resize the moment a bar was pressed. An overlay draws on top without
/// touching the chart's size at all.
///
/// Its own `@State` (not passed in) so two instances on screen at once — e.g. the
/// Claude and Codex charts in the same scroll view — track separate selections
/// instead of fighting over one shared value.
public struct HourlyChartSection: View {
    private let points: [HourlyUsagePoint]
    private let color: Color
    private let useGradient: Bool
    private let title: String
    private let hourAxisLabel: String
    private let tokenAxisLabel: String

    @State private var selectedPoint: HourlyUsagePoint?

    public init(points: [HourlyUsagePoint], color: Color, useGradient: Bool, title: String, hourAxisLabel: String, tokenAxisLabel: String) {
        self.points = points
        self.color = color
        self.useGradient = useGradient
        self.title = title
        self.hourAxisLabel = hourAxisLabel
        self.tokenAxisLabel = tokenAxisLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Chart(points) { point in
                BarMark(
                    x: .value(hourAxisLabel, point.hourStart, unit: .hour),
                    y: .value(tokenAxisLabel, point.tokens)
                )
                .foregroundStyle(
                    useGradient
                        ? AnyShapeStyle(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .bottom, endPoint: .top))
                        : AnyShapeStyle(color)
                )
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in updateSelection(proxy: proxy, geo: geo, location: value.location) }
                                .onEnded { _ in selectedPoint = nil }
                        )
                        .overlay(alignment: .topLeading) {
                            if let selectedPoint, let plotFrameAnchor = proxy.plotFrame,
                               let xPosition = proxy.position(forX: selectedPoint.hourStart) {
                                let plotFrame = geo[plotFrameAnchor]
                                calloutView(for: selectedPoint)
                                    .fixedSize()
                                    .offset(y: -30)
                                    .position(x: plotFrame.minX + xPosition, y: plotFrame.minY)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.1), value: selectedPoint)
                }
            }
        }
    }

    private func updateSelection(proxy: ChartProxy, geo: GeometryProxy, location: CGPoint) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            selectedPoint = nil
            return
        }
        let plotFrame = geo[plotFrameAnchor]
        let xInPlot = location.x - plotFrame.origin.x
        guard xInPlot >= 0, xInPlot <= plotFrame.width, let date: Date = proxy.value(atX: xInPlot) else {
            selectedPoint = nil
            return
        }
        selectedPoint = points.min { abs($0.hourStart.timeIntervalSince(date)) < abs($1.hourStart.timeIntervalSince(date)) }
    }

    private func calloutView(for point: HourlyUsagePoint) -> some View {
        VStack(spacing: 2) {
            Text(Self.hourFormatter.string(from: point.hourStart)).font(.caption2.bold())
            Text(Self.numberFormatter.string(from: NSNumber(value: point.tokens)) ?? "\(point.tokens)").font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
