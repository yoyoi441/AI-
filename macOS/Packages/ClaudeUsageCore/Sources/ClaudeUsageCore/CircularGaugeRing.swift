import SwiftUI

/// A ring-shaped capacity indicator (donut style) sharing `GaugeBar`'s color/gradient
/// customization — used in the widget, where a compact circular shape reads better
/// than a horizontal bar.
public struct CircularGaugeRing<Center: View>: View {
    private let fraction: Double
    private let color: Color
    private let useGradient: Bool
    private let lineWidth: CGFloat
    private let center: Center

    public init(
        fraction: Double,
        color: Color,
        useGradient: Bool,
        lineWidth: CGFloat = 7,
        @ViewBuilder center: () -> Center
    ) {
        self.fraction = min(1, max(0, fraction))
        self.color = color
        self.useGradient = useGradient
        self.lineWidth = lineWidth
        self.center = center()
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fillStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
    }

    private var fillStyle: AnyShapeStyle {
        guard useGradient else { return AnyShapeStyle(color) }
        return AnyShapeStyle(
            AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * fraction))
        )
    }
}

public extension CircularGaugeRing where Center == EmptyView {
    init(fraction: Double, color: Color, useGradient: Bool, lineWidth: CGFloat = 7) {
        self.init(fraction: fraction, color: color, useGradient: useGradient, lineWidth: lineWidth) { EmptyView() }
    }
}
