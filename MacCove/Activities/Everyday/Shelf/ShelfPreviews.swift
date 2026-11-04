//
//  ShelfPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private let files = ["Proposal.pdf", "Hero shot.jpg", "Budget.numbers"]

private func compact(_ shelf: FileShelf) -> some View {
    IslandPreview(
        size: CGSize(width: ShelfCompactView.width(for: shelf, notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        ShelfCompactView(shelf: shelf, notchSize: notch)
    }
}

private func expanded(_ shelf: FileShelf) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + ShelfExpandedView.bodyHeight(for: shelf)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        ShelfExpandedView(shelf: shelf, notchHeight: notch.height)
    }
}

#Preview("Holding files") {
    compact(.preview(files))
}

#Preview("Expanded") {
    expanded(.preview(files))
}

#Preview("Expanded, more than fit") {
    expanded(.preview(files + ["Notes.txt", "Invoice 2026-11.pdf", "Logo.svg"]))
}

#Preview("Dragging near") {
    compact(.preview([], dragPhase: .near))
}

#Preview("Dragging near, holding files") {
    compact(.preview(files, dragPhase: .near))
}

#Preview("Dragging over") {
    expanded(.preview(files, dragPhase: .over, dragged: ["Proposal.pdf"]))
}

#Preview("Dragging over AirDrop") {
    expanded(.preview([], dragPhase: .over, dragged: ["Hero shot.jpg", "Budget.numbers"], dropZone: .airDrop))
}
#endif
