//
//  ShelfViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI
import UniformTypeIdentifiers

extension ShapeStyle where Self == Color {
    /// The design's blue for somewhere to drop files.
    static var shelfDrop: Color {
        Color(red: 10 / 255, green: 132 / 255, blue: 1)
    }
}

/// The design's tray, open at the front, drawn in a 24pt box.
nonisolated private struct TrayShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 4, y: 13.5))
        path.addLine(to: CGPoint(x: 6.5, y: 5.5))
        path.addLine(to: CGPoint(x: 17.5, y: 5.5))
        path.addLine(to: CGPoint(x: 20, y: 13.5))
        path.addLine(to: CGPoint(x: 20, y: 18.5))
        path.addArc(tangent1End: CGPoint(x: 20, y: 20), tangent2End: CGPoint(x: 18.5, y: 20), radius: 1.5)
        path.addLine(to: CGPoint(x: 5.5, y: 20))
        path.addArc(tangent1End: CGPoint(x: 4, y: 20), tangent2End: CGPoint(x: 4, y: 18.5), radius: 1.5)
        path.closeSubpath()
        // The dip in its floor.
        path.move(to: CGPoint(x: 4, y: 13.5))
        path.addLine(to: CGPoint(x: 8.5, y: 13.5))
        path.addLine(to: CGPoint(x: 9.5, y: 15.5))
        path.addLine(to: CGPoint(x: 14.5, y: 15.5))
        path.addLine(to: CGPoint(x: 15.5, y: 13.5))
        path.addLine(to: CGPoint(x: 20, y: 13.5))
        return fitted(path, in: rect)
    }
}

/// The design's AirDrop: a dot under two rings open at the bottom.
nonisolated private struct AirDropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: 12, y: 13.5)
        var path = Path()
        path.addEllipse(in: CGRect(x: centre.x - 1.5, y: centre.y - 1.5, width: 3, height: 3))
        // Each ring from its lower left, over the top, to its lower right.
        path.addRelativeArc(center: centre, radius: 5.5, startAngle: .degrees(140.5), delta: .degrees(259))
        path.addRelativeArc(center: centre, radius: 9.5, startAngle: .degrees(136.8), delta: .degrees(266.4))
        return fitted(path, in: rect)
    }
}

/// A path drawn in a 24pt box, scaled to and centred in `rect`.
nonisolated private func fitted(_ path: Path, in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    return path
        .applying(CGAffineTransform(scaleX: scale, y: scale))
        .offsetBy(dx: rect.midX - 12 * scale, dy: rect.midY - 12 * scale)
}

private struct ShelfGlyph: View {
    var isAirDrop = false
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        Group {
            if isAirDrop {
                AirDropShape().stroke(color, style: style)
            } else {
                TrayShape().stroke(color, style: style)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var style: StrokeStyle {
        StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round)
    }
}

/// "1 file", "3 files".
private func fileCount(_ count: Int) -> String {
    count == 1 ? "1 file" : "\(count) files"
}

/// The tray in the left wing and how many files it holds in the right. A
/// file dragged near turns both blue and says Drop.
struct ShelfCompactView: View {
    let shelf: FileShelf
    let notchSize: CGSize

    private static let trailingFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    /// Between the text and the notch, as the artwork has.
    private static let notchGap: CGFloat = 12

    /// Wide enough for the count and for Drop, so the pill doesn't change
    /// size as a drag comes near, and the same on both sides so the notch
    /// stays in the middle.
    static func width(for shelf: FileShelf, notch: CGSize) -> CGFloat {
        let layout = CompactLayout(notch: notch)
        var texts = ["Drop"]
        if !shelf.items.isEmpty {
            texts.append(fileCount(shelf.items.count))
        }
        let textWidth = texts
            .map { ($0 as NSString).size(withAttributes: [.font: trailingFont]).width.rounded(.up) }
            .max() ?? 0
        return notch.width + (layout.sideInset + max(layout.artSize, textWidth) + notchGap) * 2
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let isDropping = shelf.dragPhase != nil
        let color: Color = isDropping ? .shelfDrop : .white

        HStack(spacing: 0) {
            ShelfGlyph(size: layout.artSize, color: color)
            Spacer(minLength: 0)
            Text(isDropping ? "Drop" : fileCount(shelf.items.count))
                .foregroundStyle(color)
        }
        .font(.system(size: 15, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, layout.sideInset)
        .frame(width: Self.width(for: shelf, notch: notchSize), height: notchSize.height)
        .animation(.easeOut(duration: 0.15), value: isDropping)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDropping ? "Drop files on the shelf" : "Shelf, \(fileCount(shelf.items.count))")
        .accessibilityAddTraits(.isButton)
    }
}

/// The tray in a bubble beside another activity.
struct ShelfMinimalView: View {
    let shelf: FileShelf
    let notchSize: CGSize

    var body: some View {
        ShelfGlyph(size: BubbleLayout(notch: notchSize).artSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Shelf, \(fileCount(shelf.items.count))")
            .accessibilityAddTraits(.isButton)
    }
}

/// Opened up. The files on the shelf, each dragged straight out into any
/// app, clicked to open, or right-clicked for more, with Clear and AirDrop
/// All. A file dragged over it: somewhere to keep it, or to AirDrop it.
struct ShelfExpandedView: View {
    let shelf: FileShelf
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let tileSize: CGFloat = 44
    private static let filesGap: CGFloat = 12
    fileprivate static let fileWidth: CGFloat = 84
    private static let fileSpacing: CGFloat = 8
    fileprivate static let thumbnailSize: CGFloat = 64
    fileprivate static let nameGap: CGFloat = 6
    fileprivate static let nameHeight: CGFloat = 14
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let dropGap: CGFloat = 12
    private static let dropHeight: CGFloat = 96
    private static let dropSpacing: CGFloat = 10
    private static let bottomGap: CGFloat = 14

    private static var fileHeight: CGFloat {
        thumbnailSize + nameGap + nameHeight
    }

    static func bodyHeight(for shelf: FileShelf) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        if shelf.dragPhase != nil {
            height += dropGap + dropHeight
        } else {
            if !shelf.items.isEmpty {
                height += filesGap + fileHeight
            }
            height += chipsGap + chipHeight
        }
        return height
    }

    /// Where a drag at `offset` would go: the right half of the drop row
    /// is AirDrop, and anywhere else on the open notch is the shelf.
    /// Measured from the top of the notch along its centre line.
    static func dropZone(at offset: CGPoint, notchHeight: CGFloat) -> FileShelf.DropZone {
        let rowTop = notchHeight + NotchViewModel.expandedTopGap + headerHeight + dropGap
        return offset.y >= rowTop && offset.x >= 0 ? .airDrop : .shelf
    }

    var body: some View {
        VStack(spacing: 0) {
            if shelf.dragPhase != nil {
                dropping
            } else {
                holding
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    // MARK: - Holding files

    @ViewBuilder
    private var holding: some View {
        let count = shelf.items.count
        header(
            title: "Shelf",
            subtitle: count == 1 ? "1 file · drag it out to use it" : "\(count) files · drag them out to use them",
            isDropping: false
        )
        if !shelf.items.isEmpty {
            files
                .padding(.top, Self.filesGap)
        }
        HStack(spacing: 8) {
            chip("Clear") { shelf.clear() }
            chip("AirDrop All", background: .shelfDrop) { shelf.airDropAll() }
        }
        .padding(.top, Self.chipsGap)
    }

    /// As many as fit, then the rest a scroll away.
    private var files: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.fileSpacing) {
                ForEach(shelf.items) { item in
                    ShelfFileTile(shelf: shelf, item: item)
                }
            }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Self.fileHeight)
    }

    // MARK: - A drag over it

    @ViewBuilder
    private var dropping: some View {
        let them = shelf.draggedCount > 1 ? "them" : "it"
        header(
            title: shelf.dropZone == .airDrop ? "Drop to AirDrop \(them)" : "Drop to keep \(them) here",
            subtitle: draggedSubtitle,
            isDropping: true
        )
        HStack(spacing: Self.dropSpacing) {
            dropZone(.shelf, label: "Shelf")
            dropZone(.airDrop, label: "AirDrop")
        }
        .frame(height: Self.dropHeight)
        .padding(.top, Self.dropGap)
    }

    /// The file by name, or how many there are: promised files have no
    /// names until they're saved.
    private var draggedSubtitle: String {
        let names = shelf.draggedNames
        if let first = names.first {
            return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
        }
        return shelf.draggedCount > 0 ? fileCount(shelf.draggedCount) : "Keep it here, or AirDrop it"
    }

    private func dropZone(_ zone: FileShelf.DropZone, label: String) -> some View {
        let isTargeted = shelf.dropZone == zone
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return VStack(spacing: 6) {
            ShelfGlyph(isAirDrop: zone == .airDrop, size: 26, color: isTargeted ? .white : .islandSecondary)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isTargeted ? Color.white : Color.islandSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isTargeted ? Color.shelfDrop.opacity(0.18) : .clear))
        .overlay(shape.strokeBorder(
            isTargeted ? Color.shelfDrop : .white.opacity(0.25),
            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
        ))
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isTargeted ? .isSelected : [])
    }

    // MARK: - Parts

    private func header(title: String, subtitle: String, isDropping: Bool) -> some View {
        HStack(spacing: 12) {
            ShelfGlyph(size: 26, color: isDropping ? .shelfDrop : .white)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                // The tray itself carries every file at once.
                .overlay {
                    if !isDropping, !shelf.items.isEmpty {
                        ShelfDragHandle(
                            shelf: shelf,
                            items: shelf.items,
                            label: "Drag all files",
                            toolTip: "Drag to take every file"
                        )
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .frame(height: Self.headerHeight)
    }

    private func chip(
        _ label: String,
        background: Color = .white.opacity(0.12),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A file on the shelf: its preview and its name.
private struct ShelfFileTile: View {
    let shelf: FileShelf
    let item: FileShelf.Item

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: ShelfExpandedView.nameGap) {
            Image(nsImage: thumbnail ?? icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: ShelfExpandedView.thumbnailSize, height: ShelfExpandedView.thumbnailSize)
            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.86))
                .frame(width: ShelfExpandedView.fileWidth - 4, height: ShelfExpandedView.nameHeight)
        }
        .frame(width: ShelfExpandedView.fileWidth)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.08 : 0))
        )
        .accessibilityHidden(true)
        .overlay {
            ShelfDragHandle(shelf: shelf, items: [item], label: item.name, toolTip: item.name) { isHovering in
                isHovered = isHovering
            }
        }
        .task(id: item.url) {
            let size = CGSize(width: ShelfExpandedView.thumbnailSize, height: ShelfExpandedView.thumbnailSize)
            guard let image = await FileShelf.thumbnail(of: item.url, size: size, scale: displayScale) else { return }
            thumbnail = NSImage(
                cgImage: image,
                size: NSSize(width: CGFloat(image.width) / displayScale, height: CGFloat(image.height) / displayScale)
            )
        }
    }

    /// Until the preview is ready: the icon for its kind of file.
    private var icon: NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: item.url.pathExtension) ?? .data)
    }
}

/// Where files on the shelf are picked up and dragged out. SwiftUI's own
/// dragging can't say when a drag has landed, which the shelf needs to let
/// go of the file, so this is AppKit's.
private struct ShelfDragHandle: NSViewRepresentable {
    let shelf: FileShelf
    let items: [FileShelf.Item]
    let label: String
    let toolTip: String
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ShelfDragHandleView {
        ShelfDragHandleView()
    }

    func updateNSView(_ view: ShelfDragHandleView, context: Context) {
        view.shelf = shelf
        view.items = items
        view.onHover = onHover
        view.toolTip = toolTip
        view.setAccessibilityLabel(label)
    }
}

/// A click on a single file opens it; a drag carries its files out; a
/// right-click on a single file has Open, Show in Finder and Remove.
final class ShelfDragHandleView: NSView {
    weak var shelf: FileShelf?
    var items: [FileShelf.Item] = []
    var onHover: (Bool) -> Void = { _ in }

    /// The mouse down a drag would start from.
    private var press: NSEvent?
    /// How far the mouse goes before a click becomes a drag.
    private static let dragDistance: CGFloat = 3

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        press = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let shelf else { return }
        let start = press.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= Self.dragDistance else { return }
        self.press = nil
        onHover(false)
        shelf.beginDrag(items, from: self, event: press)
    }

    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }
        press = nil
        openSingleFile()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shelf, items.count == 1, let item = items.first else { return nil }
        let menu = NSMenu()
        menu.addItem(ShelfMenuAction.item("Open") { shelf.open(item) })
        menu.addItem(ShelfMenuAction.item("Show in Finder") { shelf.reveal(item) })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuAction.item("Remove from Shelf") { shelf.remove([item.id]) })
        return menu
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        openSingleFile()
        return items.count == 1
    }

    private func openSingleFile() {
        guard let shelf, items.count == 1, let item = items.first else { return }
        shelf.open(item)
    }
}

/// A menu item that runs a closure. The item keeps it, since a menu item's
/// target isn't retained and the notch may close, taking the view that made
/// the menu, while the menu is still open.
private final class ShelfMenuAction: NSObject {
    private let action: () -> Void

    private init(_ action: @escaping () -> Void) {
        self.action = action
    }

    static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = ShelfMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }

    @objc private func run() {
        action()
    }
}
