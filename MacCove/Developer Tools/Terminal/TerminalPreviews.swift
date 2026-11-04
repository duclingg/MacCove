//
//  TerminalPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func command(_ phase: TerminalCommandMonitor.Phase, ranFor seconds: TimeInterval = 134) -> TerminalCommandMonitor.Command {
    TerminalCommandMonitor.Command(
        id: "preview",
        text: "npm run build",
        directory: URL.homeDirectory.appending(path: "Developer/site").path(percentEncoded: false),
        shellPID: nil,
        tty: "/dev/ttys003",
        appBundleIdentifier: "com.apple.Terminal",
        startedAt: .now.addingTimeInterval(-seconds),
        finishedAt: phase == .running ? nil : .now,
        phase: phase
    )
}

private func compact(_ command: TerminalCommandMonitor.Command) -> some View {
    IslandPreview(
        size: CGSize(width: TerminalCompactView.width(for: command, notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        TerminalCompactView(terminal: .preview(command), notchSize: notch)
    }
}

private func expanded(_ command: TerminalCommandMonitor.Command) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + TerminalExpandedView.bodyHeight(for: command)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        TerminalExpandedView(terminal: .preview(command), notchHeight: notch.height)
    }
}

#Preview("Running") {
    compact(command(.running, ranFor: 84))
}

#Preview("Finished") {
    compact(command(.finished))
}

#Preview("Failed") {
    compact(command(.failed(exitCode: 1), ranFor: 48))
}

#Preview("Running, expanded") {
    expanded(command(.running, ranFor: 84))
}

#Preview("Finished, expanded") {
    expanded(command(.finished))
}

#Preview("Failed, expanded") {
    expanded(command(.failed(exitCode: 1), ranFor: 48))
}
#endif
