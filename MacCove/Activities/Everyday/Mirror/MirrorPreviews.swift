//
//  MirrorPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func compact(_ mirror: MirrorCamera) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        MirrorCompactView(mirror: mirror, notchSize: notch)
    }
}

private func expanded(_ mirror: MirrorCamera) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + MirrorExpandedView.bodyHeight),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        MirrorExpandedView(mirror: mirror, notchHeight: notch.height)
    }
}

#Preview("Camera on") {
    compact(.preview(status: .running))
}

/// The preview stays blank here: the camera never turns on in previews.
#Preview("Expanded") {
    expanded(.preview(status: .running))
}

#Preview("Turning on") {
    expanded(.preview(status: .starting))
}

#Preview("No access") {
    expanded(.preview(status: .denied))
}

#Preview("No camera") {
    expanded(.preview(status: .noCamera))
}
#endif
