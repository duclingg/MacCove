#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private let link = ClipboardMonitor.previewItem(.link, "https://github.com/duclingg/MacCove/pull/6", from: "Safari")

private let history = [
    link,
    ClipboardMonitor.previewItem(.text, "Meeting moved to 3:30, same link", from: "Messages", minutesAgo: 4),
    ClipboardMonitor.previewItem(.image, "Screenshot 2026-11-02 at 2.41 PM", from: "Finder", minutesAgo: 12),
    ClipboardMonitor.previewItem(.color, "#3E9BFF", from: "Figma", minutesAgo: 64),
]

private func compact(_ clipboard: ClipboardMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        ClipboardCompactView(clipboard: clipboard, notchSize: notch)
    }
}

private func expanded(_ clipboard: ClipboardMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + ClipboardExpandedView.bodyHeight(for: clipboard)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        ClipboardExpandedView(clipboard: clipboard, notchHeight: notch.height)
    }
}

#Preview("Copied") {
    compact(.preview(.copied(link), history: history))
}

#Preview("Password") {
    compact(.preview(.concealed(sourceName: "1Password")))
}

#Preview("Copied, expanded") {
    expanded(.preview(.copied(link), history: history))
}

#Preview("Text, expanded") {
    let note = ClipboardMonitor.previewItem(.text, "Meeting moved to 3:30, same link. Bring the notes from Tuesday and the new mockups for the settings window.", from: "Messages")
    return expanded(.preview(.copied(note)))
}

#Preview("Colour, expanded") {
    expanded(.preview(.copied(history[3])))
}

#Preview("History") {
    expanded(.preview(.history, history: history))
}

#Preview("History, paused") {
    expanded(.preview(.history, history: history, pausedUntil: .now.addingTimeInterval(3600)))
}

#Preview("History, empty") {
    expanded(.preview(.history))
}

#Preview("Password, expanded") {
    expanded(.preview(.concealed(sourceName: "1Password")))
}
#endif
