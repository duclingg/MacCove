//
//  DownloadViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import SwiftUI

extension Color {
    /// The design's blue for downloads coming in, and for Open.
    static let downloadBlue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    fileprivate static let codeText = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.86)
}

/// The design's download glyph: an arrow pointing down into a circle,
/// drawn on a 24pt grid.
nonisolated private struct DownloadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
        path.move(to: CGPoint(x: 12, y: 7.5))
        path.addLine(to: CGPoint(x: 12, y: 15.5))
        path.move(to: CGPoint(x: 8.5, y: 12.5))
        path.addLine(to: CGPoint(x: 12, y: 16))
        path.addLine(to: CGPoint(x: 15.5, y: 12.5))
        let scale = min(rect.width, rect.height) / 24
        return path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.midX - 12 * scale, dy: rect.midY - 12 * scale)
    }
}

private struct DownloadGlyph: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        DownloadShape()
            .stroke(color, style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// How much has arrived in blue over a dim track, or a spinning arc while
/// the size isn't known.
private struct DownloadRing: View {
    let progress: Double?
    /// Across the outside of the stroke.
    let diameter: CGFloat
    let lineWidth: CGFloat
    var trackOpacity = 0.2

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        ZStack {
            Circle()
                .stroke(.white.opacity(trackOpacity), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.downloadBlue, style: style)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: progress)
            } else {
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Color.downloadBlue, style: style)
                        .rotationEffect(.degrees(spin(at: context.date) * 360))
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
    }

    /// 0 to 1 over each 1.2 seconds.
    private func spin(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
    }
}

// MARK: - Text

/// Decimal units, as the Finder counts: the number and its unit.
private func byteParts(_ bytes: Int64, unit: Int? = nil) -> (number: String, unit: String) {
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    var exponent = 0
    var value = Double(max(0, bytes))
    if let unit {
        exponent = unit
        value /= pow(1000, Double(unit))
    } else {
        while value >= 1000, exponent < units.count - 1 {
            value /= 1000
            exponent += 1
        }
    }
    // A tenth of a gigabyte is still a lot; a tenth of a megabyte isn't.
    let number = exponent == 0 ? "\(Int(value))"
        : exponent >= 3 || value < 10 ? String(format: "%.1f", value)
        : "\(Int(value.rounded()))"
    return (number, units[exponent])
}

private func byteUnit(_ bytes: Int64) -> Int {
    var exponent = 0
    var value = Double(max(0, bytes))
    while value >= 1000, exponent < 4 {
        value /= 1000
        exponent += 1
    }
    return exponent
}

/// "11.9 GB".
private func byteString(_ bytes: Int64) -> String {
    let parts = byteParts(bytes)
    return "\(parts.number) \(parts.unit)"
}

/// "4.2 of 11.9 GB", or just what has arrived while the size isn't known.
private func progressString(received: Int64, total: Int64?) -> String {
    guard let total else { return byteString(received) }
    let unit = byteUnit(total)
    let parts = byteParts(total, unit: unit)
    return "\(byteParts(received, unit: unit).number) of \(parts.number) \(parts.unit)"
}

/// "28 MB/s".
private func speedString(_ bytesPerSecond: Double) -> String {
    "\(byteString(Int64(bytesPerSecond)))/s"
}

/// "12 sec left", "6 min left", "1 hr 5 min left".
private func timeLeftString(_ seconds: TimeInterval) -> String {
    let seconds = max(1, Int(seconds.rounded()))
    if seconds < 60 { return "\(seconds) sec left" }
    let minutes = Int((Double(seconds) / 60).rounded())
    if minutes < 60 { return "\(minutes) min left" }
    return "\(minutes / 60) hr \(minutes % 60) min left"
}

private func percentString(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded(.down)))%"
}

private func plural(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
}

// MARK: - Views

/// The download glyph in the left wing. In the right: the ring, for all of
/// them together, while they come in, then a green check.
struct DownloadCompactView: View {
    let monitor: DownloadMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = CompactLayout(notch: notchSize)

        HStack(spacing: 0) {
            DownloadGlyph(color: .downloadBlue, size: layout.artSize)
            Spacer(minLength: 0)
            if monitor.isFinished {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.islandSucceeded)
                    .frame(width: layout.artSize, height: layout.artSize)
            } else if !monitor.downloads.isEmpty {
                DownloadRing(progress: monitor.fraction, diameter: 20, lineWidth: 3)
                    .frame(width: layout.artSize, height: layout.artSize)
            }
        }
        .padding(.horizontal, layout.sideInset)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityDescription(monitor))
        .accessibilityAddTraits(.isButton)
    }

    private static func accessibilityDescription(_ monitor: DownloadMonitor) -> String {
        if monitor.isFinished, let finished = monitor.lastFinished {
            return "\(finished.name) downloaded"
        }
        let count = monitor.downloads.count
        let what = count == 1 ? "Downloading \(monitor.downloads[0].name)" : "\(count) downloads"
        guard let fraction = monitor.fraction else { return what }
        return "\(what), \(percentString(fraction)) done"
    }
}

/// Downloads in a bubble beside another activity: the glyph inside the
/// ring while they come in, then green.
struct DownloadMinimalView: View {
    let monitor: DownloadMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)

        Group {
            if monitor.isFinished {
                DownloadGlyph(color: .islandSucceeded, size: layout.artSize)
            } else {
                ZStack {
                    DownloadRing(
                        progress: monitor.fraction,
                        diameter: layout.ringDiameter,
                        lineWidth: layout.ringLineWidth,
                        trackOpacity: 0.18
                    )
                    DownloadGlyph(color: .downloadBlue, size: (layout.ringDiameter * 0.55).rounded())
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloads")
        .accessibilityAddTraits(.isButton)
    }
}

/// Opened up. One download: its name, where it's from and how much has
/// arrived, a bar, then the time left and speed. Several: the same for
/// them all, and each one listed. Finished: the file, to open or drag out
/// of the notch.
struct DownloadExpandedView: View {
    let monitor: DownloadMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let barGap: CGFloat = 10
    private static let barHeight: CGFloat = 6
    private static let footerGap: CGFloat = 6
    private static let footerHeight: CGFloat = 16
    private static let codeGap: CGFloat = 10
    private static let codePadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    private static let codeLineHeight: CGFloat = 18
    /// Downloads listed by name; past this, how many more.
    private static let maxListedLines = 4
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    static func bodyHeight(for monitor: DownloadMonitor) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        if monitor.isFinished {
            height += chipsGap + chipHeight
        } else if !monitor.downloads.isEmpty {
            height += barGap + barHeight + footerGap + footerHeight
            let lines = listLines(for: monitor).count
            if lines > 0 {
                height += codeGap + codePadding.top + codeLineHeight * CGFloat(lines) + codePadding.bottom
            }
        }
        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            if monitor.isFinished, let finished = monitor.lastFinished {
                finishedHeader(finished)
                buttons
                    .padding(.top, Self.chipsGap)
            } else if !monitor.downloads.isEmpty {
                runningHeader
                progress
                let lines = Self.listLines(for: monitor)
                if !lines.isEmpty {
                    list(lines)
                        .padding(.top, Self.codeGap)
                }
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private func tile(_ color: Color) -> some View {
        DownloadGlyph(color: color, size: 26)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func titles(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .truncationMode(.middle)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.islandSecondary)
                .truncationMode(.tail)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var runningHeader: some View {
        let downloads = monitor.downloads

        return HStack(spacing: 12) {
            Button {
                monitor.showInFinder()
            } label: {
                tile(.downloadBlue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show in Finder")

            if downloads.count == 1 {
                titles(downloads[0].name, Self.subtitle(downloads[0]))
            } else {
                titles(plural(downloads.count, "download"), Self.subtitle(monitor))
            }

            Button {
                monitor.showInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show in Finder")
        }
        .frame(height: Self.headerHeight)
    }

    /// "Safari · 4.2 of 11.9 GB".
    private static func subtitle(_ download: DownloadMonitor.Download) -> String {
        let size = progressString(received: download.receivedBytes, total: download.totalBytes)
        return download.source.map { "\($0) · \(size)" } ?? size
    }

    /// "6.9 of 13.3 GB · 6 min left".
    private static func subtitle(_ monitor: DownloadMonitor) -> String {
        let size = progressString(received: monitor.receivedBytes, total: monitor.totalBytes)
        return monitor.secondsLeft.map { "\(size) · \(timeLeftString($0))" } ?? size
    }

    /// The file can be dragged straight out of the notch into any app, or
    /// clicked to open.
    private func finishedHeader(_ finished: DownloadMonitor.Download) -> some View {
        HStack(spacing: 12) {
            tile(.islandSucceeded)
                .accessibilityHidden(true)
            titles(finished.name, "Downloaded · \(byteString(finished.receivedBytes)) · drag it out of here")
                .accessibilityHidden(true)
        }
        .frame(height: Self.headerHeight)
        .overlay {
            DownloadDragHandle(
                url: finished.url,
                label: "\(finished.name), downloaded, \(byteString(finished.receivedBytes))",
                open: { monitor.openFinished() },
                dropped: { monitor.dismiss() }
            )
        }
    }

    /// The bar fills for them all together. Under it, how far along and,
    /// with one, the time left; then the speed.
    private var progress: some View {
        let fraction = monitor.fraction
        let isSeveral = monitor.downloads.count > 1
        var trailing: [String] = []
        if !isSeveral, let left = monitor.secondsLeft {
            trailing.append(timeLeftString(left))
        }
        if let speed = monitor.bytesPerSecond {
            trailing.append(speedString(speed))
        }
        let leading = fraction.map { percentString($0) + (isSeveral ? " overall" : "") }
            ?? byteString(monitor.receivedBytes)

        return VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.downloadBlue)
                            .frame(width: proxy.size.width * (fraction ?? 0))
                            .animation(.easeInOut(duration: 0.4), value: fraction)
                    }
                }
                .frame(height: Self.barHeight)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text(leading)
                Spacer(minLength: 0)
                Text(trailing.joined(separator: " · "))
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.islandSecondary)
            .lineLimit(1)
            .frame(height: Self.footerHeight)
            .padding(.top, Self.footerGap)
        }
        .padding(.top, Self.barGap)
    }

    private struct ListLine: Identifiable {
        let id: Int
        let name: String
        let state: String
        let color: Color
    }

    /// Each one, while there are several: how far along, or Done in green.
    private static func listLines(for monitor: DownloadMonitor) -> [ListLine] {
        let downloads = monitor.downloads
        guard downloads.count > 1 else { return [] }
        let shown = downloads.count > maxListedLines ? maxListedLines - 1 : downloads.count
        var lines = downloads.prefix(shown).enumerated().map { index, download in
            ListLine(
                id: index,
                name: download.name,
                state: download.isFinished ? "Done" : download.fraction.map(percentString) ?? byteString(download.receivedBytes),
                color: download.isFinished ? .islandSucceeded : .codeText
            )
        }
        if downloads.count > shown {
            lines.append(ListLine(id: shown, name: "\(downloads.count - shown) more", state: "", color: .codeText))
        }
        return lines
    }

    private func list(_ lines: [ListLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(spacing: 12) {
                    Text(line.name)
                        .foregroundStyle(Color.codeText)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(line.state)
                        .foregroundStyle(line.color)
                }
                .lineLimit(1)
                .frame(height: Self.codeLineHeight)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(Self.codePadding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            chip("Show in Finder") { monitor.showInFinder() }
            chip("Open", background: .downloadBlue) { monitor.openFinished() }
        }
    }

    private func chip(
        _ label: String,
        background: Color = .white.opacity(0.12),
        foreground: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Where a finished download is picked up and dragged out. AppKit's, as
/// the shelf's is, so the notch can stop taking the mouse while the file is
/// on its way: otherwise its own drop target would see the file go past.
private struct DownloadDragHandle: NSViewRepresentable {
    let url: URL
    let label: String
    let open: () -> Void
    /// Let go somewhere that took it.
    let dropped: () -> Void

    func makeNSView(context: Context) -> DownloadDragHandleView {
        DownloadDragHandleView()
    }

    func updateNSView(_ view: DownloadDragHandleView, context: Context) {
        view.url = url
        view.open = open
        view.dropped = dropped
        view.toolTip = "Drag it anywhere, or click to open it"
        view.setAccessibilityLabel(label)
    }
}

/// A click opens the file; a drag carries it out, moving it on the same
/// disk and copying it to another, as the Finder does.
private final class DownloadDragHandleView: NSView, NSDraggingSource {
    var url: URL?
    var open: () -> Void = {}
    var dropped: () -> Void = {}

    /// The mouse down a drag would start from.
    private var press: NSEvent?
    /// How far the mouse goes before a click becomes a drag.
    private static let dragDistance: CGFloat = 3
    private static let imageSize = NSSize(width: 48, height: 48)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        press = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let url else { return }
        let start = press.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= Self.dragDistance else { return }
        self.press = nil

        let point = convert(start, from: nil)
        let size = Self.imageSize
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(
            NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        )
        let session = beginDraggingSession(with: [item], event: press, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        // The open notch covers whatever's below the menu bar there, and
        // would take the drop itself.
        window?.ignoresMouseEvents = true
    }

    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }
        press = nil
        open()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard !operation.isEmpty else { return }
        dropped()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityHelp() -> String? { "Opens it" }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }
}
