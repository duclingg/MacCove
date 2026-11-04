//
//  DownloadPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func download(
    _ name: String,
    received: Int64,
    total: Int64?,
    source: String? = "Safari",
    bytesPerSecond: Double? = 28_000_000,
    isFinished: Bool = false
) -> DownloadMonitor.Download {
    DownloadMonitor.Download(
        id: UUID(),
        url: URL.downloadsDirectory.appending(path: name),
        source: source,
        receivedBytes: received,
        totalBytes: total,
        bytesPerSecond: isFinished ? nil : bytesPerSecond,
        isFinished: isFinished
    )
}

private let xcode = download("Xcode_26.2.xip", received: 4_165_000_000, total: 11_900_000_000)
private let several = [
    download("Xcode_26.2.xip", received: 4_165_000_000, total: 11_900_000_000, bytesPerSecond: 20_000_000),
    download("Design review.mov", received: 1_092_000_000, total: 1_400_000_000, bytesPerSecond: 8_000_000),
    download("Invoice 1142.pdf", received: 240_000, total: 240_000, isFinished: true),
]
private let unknownSize = download("archive.zip", received: 86_000_000, total: nil, source: "Chrome")
private let finished = download("Xcode_26.2.xip", received: 11_900_000_000, total: 11_900_000_000, isFinished: true)

private func compact(_ downloads: [DownloadMonitor.Download]) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        DownloadCompactView(monitor: .preview(downloads), notchSize: notch)
    }
}

private func expanded(_ downloads: [DownloadMonitor.Download]) -> some View {
    let monitor = DownloadMonitor.preview(downloads)
    return IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + DownloadExpandedView.bodyHeight(for: monitor)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        DownloadExpandedView(monitor: monitor, notchHeight: notch.height)
    }
}

#Preview("Downloading") {
    compact([xcode])
}

#Preview("Downloading, expanded") {
    expanded([xcode])
}

#Preview("Several at once") {
    compact(several)
}

#Preview("Several at once, expanded") {
    expanded(several)
}

#Preview("Size not known, expanded") {
    expanded([unknownSize])
}

#Preview("Finished") {
    compact([finished])
}

#Preview("Finished, expanded") {
    expanded([finished])
}
#endif
