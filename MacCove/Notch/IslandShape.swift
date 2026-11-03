import SwiftUI

/// The island's silhouette: square along the top edge of the screen, rounded
/// at the bottom, with small concave fillets ("ears") where it meets the
/// screen edge so it reads as part of the bezel, like the hardware notch.
///
/// The ears sit outside the body, so the shape's frame is `earWidth` wider
/// than the body on each side.
nonisolated struct IslandShape: Shape {
    static let earWidth: CGFloat = 8

    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ear = Self.earWidth
        let left = rect.minX + ear
        let right = rect.maxX - ear
        let bottom = rect.maxY
        let radius = min(cornerRadius, (right - left) / 2, rect.height / 2)
        // Control point offset for a cubic approximation of a quarter circle.
        let k: CGFloat = 0.5523 * ear

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: right, y: rect.minY + ear),
            control1: CGPoint(x: rect.maxX - k, y: rect.minY),
            control2: CGPoint(x: right, y: rect.minY + ear - k)
        )
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - radius, y: bottom), radius: radius)
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - radius), radius: radius)
        path.addLine(to: CGPoint(x: left, y: rect.minY + ear))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(x: left, y: rect.minY + ear - k),
            control2: CGPoint(x: rect.minX + k, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
