//
//  ShelfDropTarget.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

/// Takes files let go over the notch. The panel only receives a drag while
/// it's over the notch, which `NotchWindowController` decides as it
/// watches the drag; this works out where on the notch it is, and what to
/// do with the files.
final class ShelfDropTarget {
    /// File URLs, and promises of files still to be written, as Mail and
    /// Photos drag them.
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// Whether what's being dragged is files, or promises of them.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !Set(types).isDisjoint(with: draggedTypes)
    }

    private let viewModel: NotchViewModel

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    func entered(_ info: any NSDraggingInfo, in view: NSView) -> NSDragOperation {
        guard accepts(info) else { return [] }
        let pasteboard = info.draggingPasteboard
        let urls = Self.fileURLs(pasteboard)
        let count = urls.isEmpty ? Self.promises(pasteboard).count : urls.count
        guard count > 0 else { return [] }
        viewModel.shelf.setDragContents(names: urls.map(\.lastPathComponent), count: count)
        return updated(info, in: view)
    }

    func updated(_ info: any NSDraggingInfo, in view: NSView) -> NSDragOperation {
        guard accepts(info) else { return [] }
        // From the top of the panel and the notch's centre line, which is
        // the panel's.
        let point = view.convert(info.draggingLocation, from: nil)
        let offset = CGPoint(x: point.x - view.bounds.midX, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let zone = viewModel.state == .expanded
            ? ShelfExpandedView.dropZone(at: offset, notchHeight: viewModel.notchSize.height)
            : .shelf
        viewModel.shelf.setDropZone(zone)
        return Self.operation(for: info)
    }

    /// Off the notch, but still close by. The window controller usually
    /// says so first, from the drag's own mouse events; this covers any
    /// that don't reach it while the notch is taking the drag.
    func exited() {
        viewModel.shelf.setDropZone(.shelf)
        viewModel.fileDragMoved(near: true, over: false)
    }

    func perform(_ info: any NSDraggingInfo) -> Bool {
        guard accepts(info) else { return false }
        let zone = viewModel.shelf.dropZone
        let pasteboard = info.draggingPasteboard
        let urls = Self.fileURLs(pasteboard)
        if !urls.isEmpty {
            viewModel.fileDragEnded(keepOpen: zone == .shelf)
            viewModel.dropFiles(urls, to: zone)
            return true
        }
        let promises = Self.promises(pasteboard)
        guard !promises.isEmpty else { return false }
        viewModel.fileDragEnded(keepOpen: zone == .shelf)
        viewModel.shelf.receive(promises) { [weak viewModel] urls in
            viewModel?.dropFiles(urls, to: zone, received: true)
        }
        return true
    }

    /// Cancelled, or let go somewhere that didn't take it.
    func ended() {
        viewModel.fileDragEnded(keepOpen: false)
    }

    /// Files dragged out of the shelf itself, whose source is in MacCove,
    /// aren't taken back.
    private func accepts(_ info: any NSDraggingInfo) -> Bool {
        info.draggingSource == nil && viewModel.acceptsFileDrops
    }

    /// A copy, so the file stays where it was: the shelf only keeps track
    /// of it. Never a move, which would have the app it came from delete
    /// its own.
    private static func operation(for info: any NSDraggingInfo) -> NSDragOperation {
        let allowed = info.draggingSourceOperationMask
        let preferred: [NSDragOperation] = [.copy, .generic, .link]
        return preferred.first { allowed.contains($0) } ?? []
    }

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private static func promises(_ pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }
}
