import SwiftUI

/// The island's silhouette: square along the top edge of the screen, rounded
/// at the bottom, with small concave fillets ("ears") where it meets the
/// screen edge so it reads as part of the bezel, like the hardware notch.
///
/// The ears sit outside the body, so the shape's frame is `earWidth` wider
/// than the body on each side.
///
/// Never drawn shorter than `minHeight`, the notch's: the spring that sizes
/// the island overshoots as it shrinks, and would otherwise dip above the
/// bottom of the notch and the menu bar before settling.
nonisolated struct IslandShape: Shape {
    static let earWidth: CGFloat = 8

    var cornerRadius: CGFloat
    var minHeight: CGFloat = 0

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ear = Self.earWidth
        let left = rect.minX + ear
        let right = rect.maxX - ear
        let height = max(rect.height, minHeight)
        let bottom = rect.minY + height
        let radius = min(cornerRadius, (right - left) / 2, height / 2)
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

/// The island's body without its ears, which clips what's drawn in it.
/// Never shorter than `minHeight` either, so the overshoot doesn't clip the
/// pill's content.
nonisolated struct IslandBodyShape: Shape {
    var cornerRadius: CGFloat
    var minHeight: CGFloat = 0

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var bounds = rect
        bounds.size.height = max(rect.height, minHeight)
        return UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
            .path(in: bounds)
    }
}
