import SwiftUI

/// A capacity bar with a user-customizable color and optional gradient fill, shared by
/// the menu bar dropdown and the widget so both render identically. Used in place of
/// SwiftUI's built-in `Gauge`, whose fill color isn't reliably customizable per-user.
public struct GaugeBar: View {
    private let fraction: Double
    private let color: Color
    private let useGradient: Bool

    public init(fraction: Double, color: Color, useGradient: Bool) {
        self.fraction = min(1, max(0, fraction))
        self.color = color
        self.useGradient = useGradient
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(fillStyle)
                    .frame(width: fraction > 0 ? max(6, geometry.size.width * fraction) : 0)
            }
        }
        .frame(height: 8)
    }

    private var fillStyle: AnyShapeStyle {
        guard useGradient else { return AnyShapeStyle(color) }
        return AnyShapeStyle(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
    }
}
