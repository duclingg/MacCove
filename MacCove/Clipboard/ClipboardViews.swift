import SwiftUI

/// The design's clipboard, a board with its clip, drawn in a 24pt box.
nonisolated private struct ClipboardShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // The clip.
        path.move(to: CGPoint(x: 9, y: 3.5))
        path.addLine(to: CGPoint(x: 15, y: 3.5))
        path.addArc(tangent1End: CGPoint(x: 16, y: 3.5), tangent2End: CGPoint(x: 16, y: 4.5), radius: 1)
        path.addLine(to: CGPoint(x: 16, y: 6))
        path.addLine(to: CGPoint(x: 8, y: 6))
        path.addLine(to: CGPoint(x: 8, y: 4.5))
        path.addArc(tangent1End: CGPoint(x: 8, y: 3.5), tangent2End: CGPoint(x: 9, y: 3.5), radius: 1)
        path.closeSubpath()
        // The board, open at the top where the clip sits.
        path.move(to: CGPoint(x: 8, y: 5))
        path.addLine(to: CGPoint(x: 6.5, y: 5))
        path.addArc(tangent1End: CGPoint(x: 5, y: 5), tangent2End: CGPoint(x: 5, y: 6.5), radius: 1.5)
        path.addLine(to: CGPoint(x: 5, y: 19.5))
        path.addArc(tangent1End: CGPoint(x: 5, y: 21), tangent2End: CGPoint(x: 6.5, y: 21), radius: 1.5)
        path.addLine(to: CGPoint(x: 17.5, y: 21))
        path.addArc(tangent1End: CGPoint(x: 19, y: 21), tangent2End: CGPoint(x: 19, y: 19.5), radius: 1.5)
        path.addLine(to: CGPoint(x: 19, y: 6.5))
        path.addArc(tangent1End: CGPoint(x: 19, y: 5), tangent2End: CGPoint(x: 17.5, y: 5), radius: 1.5)
        path.addLine(to: CGPoint(x: 16, y: 5))
        let scale = min(rect.width, rect.height) / 24
        return path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.midX - 12 * scale, dy: rect.midY - 12 * scale)
    }
}

private struct ClipboardGlyph: View {
    let size: CGFloat

    var body: some View {
        ClipboardShape()
            .stroke(.white, style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "#3E9BFF" or "#39F" as a colour.
private func hexColor(_ string: String) -> Color? {
    var hex = String(string.dropFirst())
    if hex.count == 3 {
        hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

/// "Now", "4 min", "1 h".
private func copyAge(_ date: Date, at now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "Now" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) h"
}

/// The clipboard in the left wing. In the right: "Copied" in green, or
/// "Hidden" for a password; a check once you've been through the history.
struct ClipboardCompactView: View {
    let clipboard: ClipboardMonitor
    let notchSize: CGSize

    /// Each wing of the pill while there's text on the right: room for
    /// "Copied" or "Hidden".
    static let textWingWidth: CGFloat = 77

    static func width(for shown: ClipboardMonitor.Shown?, notch: CGSize) -> CGFloat {
        guard shown == .history else {
            return notch.width + textWingWidth * 2
        }
        return NotchViewModel.compactWidth(notch: notch)
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let shown = clipboard.shown

        HStack(spacing: 0) {
            ClipboardGlyph(size: layout.artSize)
            Spacer(minLength: 0)
            switch shown {
            case .copied?:
                Text("Copied")
                    .foregroundStyle(.islandSucceeded)
            case .concealed?:
                Text("Hidden")
                    .foregroundStyle(.islandSecondary)
            case .history?:
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.islandSucceeded)
                    .frame(width: layout.artSize, height: layout.artSize)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 15, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, layout.sideInset)
        .frame(width: Self.width(for: shown, notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.map { Self.accessibilityDescription($0) } ?? "Clipboard")
        .accessibilityAddTraits(.isButton)
    }

    private static func accessibilityDescription(_ shown: ClipboardMonitor.Shown) -> String {
        switch shown {
        case let .copied(item): "Copied \(item.preview)"
        case .concealed: "Copied a password"
        case .history: "Clipboard"
        }
    }
}

/// The clipboard in a bubble beside another activity.
struct ClipboardMinimalView: View {
    let notchSize: CGSize

    var body: some View {
        ClipboardGlyph(size: BubbleLayout(notch: notchSize).artSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Clipboard")
            .accessibilityAddTraits(.isButton)
    }
}

/// Opened up. A copy: what it was and where from, with Clear and Show
/// History. A password: only that it was copied, and isn't kept. The
/// history: the last few copies, each copied again with a click, with
/// Clear History and Pause for 1 Hour.
struct ClipboardExpandedView: View {
    let clipboard: ClipboardMonitor
    let notchHeight: CGFloat

    /// The row just clicked, which says "Copied" for a moment.
    @State private var justCopied: ClipboardMonitor.Item.ID?
    @State private var hoveredRow: ClipboardMonitor.Item.ID?

    private static let headerHeight: CGFloat = 56
    private static let codeGap: CGFloat = 10
    private static let codePadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    private static let codeLineHeight: CGFloat = 18
    private static let codeLineLimit = 3
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let codeFontLineHeight = NSLayoutManager().defaultLineHeight(for: codeFont)
    private static let swatchSize: CGFloat = 12
    private static let swatchGap: CGFloat = 8
    private static let listGap: CGFloat = 10
    private static let listPadding: CGFloat = 4
    private static let rowHeight: CGFloat = 40
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    static func bodyHeight(for clipboard: ClipboardMonitor) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        switch clipboard.shown {
        case let .copied(item)?:
            height += codeGap + codePadding.top + codeLineHeight * CGFloat(lineCount(item)) + codePadding.bottom
            height += chipsGap + chipHeight
        case .history?:
            if !clipboard.history.isEmpty {
                height += listGap + listPadding * 2 + rowHeight * CGFloat(clipboard.history.count)
            }
            height += chipsGap + chipHeight
        case .concealed?, nil:
            break
        }
        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            switch clipboard.shown {
            case let .copied(item)?:
                header(title: "Copied", subtitle: item.sourceName.map { "From \($0)" } ?? "Just now")
                code(item)
                    .padding(.top, Self.codeGap)
                HStack(spacing: 8) {
                    chip("Clear") { clipboard.clear() }
                    chip("Show History") { clipboard.showHistory() }
                }
                .padding(.top, Self.chipsGap)
            case let .concealed(sourceName)?:
                header(
                    title: "Copied a password",
                    subtitle: sourceName.map { "From \($0) · not kept in history" } ?? "Not kept in history"
                )
            case .history?:
                header(title: "Clipboard", subtitle: historySubtitle)
                if !clipboard.history.isEmpty {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        list(at: context.date)
                    }
                    .padding(.top, Self.listGap)
                }
                HStack(spacing: 8) {
                    chip("Clear History", foreground: clipboard.history.isEmpty ? .islandSecondary : .white) {
                        clipboard.clearHistory()
                    }
                    .disabled(clipboard.history.isEmpty)
                    if clipboard.pausedUntil != nil {
                        chip("Resume") { clipboard.resume() }
                    } else {
                        chip("Pause for 1 Hour") { clipboard.pause() }
                    }
                }
                .padding(.top, Self.chipsGap)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private var historySubtitle: String {
        if let pausedUntil = clipboard.pausedUntil {
            return "Paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))"
        }
        return clipboard.history.isEmpty ? "Nothing copied in the last 24 hours" : "Click one to copy it again"
    }

    private func header(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ClipboardGlyph(size: 26)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .frame(height: Self.headerHeight)
    }

    /// What was copied, as far as three lines show it. A colour has a
    /// swatch of itself beside it.
    private func code(_ item: ClipboardMonitor.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.swatchGap) {
            if item.kind == .color, let color = hexColor(item.preview) {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                    .frame(width: Self.swatchSize, height: Self.swatchSize)
                    .accessibilityHidden(true)
            }
            Text(item.preview)
                .lineLimit(Self.codeLineLimit)
                .lineSpacing(Self.codeLineHeight - Self.codeFontLineHeight)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.codeLineHeight * CGFloat(Self.lineCount(item)), alignment: .top)
        // The same SF Mono that `codeFont` measures.
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.86))
        .padding(Self.codePadding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    private func list(at now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(clipboard.history) { item in
                row(item, at: now)
            }
        }
        .padding(.vertical, Self.listPadding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    private func row(_ item: ClipboardMonitor.Item, at now: Date) -> some View {
        let isJustCopied = justCopied == item.id

        return Button {
            clipboard.copy(item)
            justCopied = item.id
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if justCopied == item.id {
                    justCopied = nil
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(for: item.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Self.tint(for: item)))
                    .accessibilityHidden(true)
                // On one line, however many it had.
                Text(item.preview.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(isJustCopied ? "Copied" : copyAge(item.copiedAt, at: now))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(isJustCopied ? Color.islandSucceeded : Color.islandSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .background(hoveredRow == item.id ? Color.white.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredRow = item.id
            } else if hoveredRow == item.id {
                hoveredRow = nil
            }
        }
        .accessibilityLabel("Copy \(item.preview)")
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

    private static func symbol(for kind: ClipboardMonitor.Kind) -> String {
        switch kind {
        case .link: "link"
        case .text, .color: "text.alignleft"
        case .image: "photo"
        case .file: "doc"
        }
    }

    /// Links in blue and pictures in purple, as in the design; a colour is
    /// its own.
    private static func tint(for item: ClipboardMonitor.Item) -> Color {
        switch item.kind {
        case .link: Color(red: 10 / 255, green: 132 / 255, blue: 1).opacity(0.35)
        case .image: Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255).opacity(0.35)
        case .color: hexColor(item.preview) ?? .white.opacity(0.12)
        case .text, .file: .white.opacity(0.12)
        }
    }

    private static let contentWidth = NotchViewModel.expandedWidth - NotchViewModel.expandedInset * 2

    /// The island's height is worked out before anything is drawn, so the
    /// copy is measured the way it will wrap, beside its swatch if it has
    /// one.
    private static func lineCount(_ item: ClipboardMonitor.Item) -> Int {
        var width = contentWidth - codePadding.leading - codePadding.trailing
        if item.kind == .color {
            width -= swatchSize + swatchGap
        }
        let bounds = NSAttributedString(string: item.preview, attributes: [.font: codeFont]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return min(max(Int((bounds.height / codeFontLineHeight).rounded()), 1), codeLineLimit)
    }
}
