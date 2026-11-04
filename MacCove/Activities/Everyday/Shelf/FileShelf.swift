//
//  FileShelf.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import QuickLookThumbnailing

/// Files dropped on the notch, kept until they're dragged out again or
/// cleared, across restarts too.
///
/// A file already on disk stays where it is and is kept by bookmark, so one
/// renamed or moved meanwhile is still found; one deleted or moved to the
/// Bin leaves the shelf. A drag that only promises a file, from Mail or
/// Photos say, is saved into Application Support first, and that copy goes
/// to the Bin when it leaves the shelf.
@Observable
final class FileShelf {
    enum Event {
        /// Files were added.
        case added
        /// The last file left.
        case emptied
    }

    /// A file drag on its way to the notch.
    enum DragPhase: Equatable {
        /// Close by: the pill widens to say Drop.
        case near
        /// Over the notch, which opens to the places to drop it.
        case over
    }

    /// Where files let go over the open notch go.
    enum DropZone: Equatable {
        case shelf
        case airDrop
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        var url: URL
        let addedAt: Date
        /// Saved into the shelf's own folder from a promised file, rather
        /// than one that was already on disk.
        let isReceived: Bool
        fileprivate var bookmark: Data

        var name: String { url.lastPathComponent }
    }

    static let enabledKey = "FileShelfEnabled"
    private static let itemsKey = "FileShelfItems"
    /// Promised files are saved here, each in a folder of its own so two
    /// with the same name don't clash.
    static let receivedFolder = URL.applicationSupportDirectory.appending(path: "MacCove/Shelf", directoryHint: .isDirectory)

    /// On until it's turned off in Settings.
    private(set) var isEnabled = UserDefaults.standard.object(forKey: FileShelf.enabledKey) as? Bool ?? true
    /// In the order they were dropped.
    private(set) var items: [Item] = []
    /// `nil` while no file drag is near the notch.
    private(set) var dragPhase: DragPhase?
    /// The files a drag over the notch carries, by name. Empty until the
    /// notch has seen them, and for promised files, which have no names
    /// until they're saved.
    private(set) var draggedNames: [String] = []
    /// How many files a drag over the notch carries, 0 until it has seen them.
    private(set) var draggedCount = 0
    /// Where a drag over the open notch would go if let go now.
    private(set) var dropZone: DropZone = .shelf

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Kept here rather than by the view that starts a drag: the notch can
    /// close under the drag and take that view with it.
    @ObservationIgnored private var dragSource: ShelfDragSource?

    /// Showing in the notch: holding files, or a drag on its way.
    var isShown: Bool {
        isEnabled && (!items.isEmpty || dragPhase != nil)
    }

    /// Picks up the files kept from last time, unless `loadsSaved` is
    /// false, for previews.
    init(loadsSaved: Bool = true) {
        if loadsSaved {
            load()
        }
    }

    /// Turned off, the shelf hides and stops taking drops, but keeps its
    /// files for when it's turned back on.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            endDrag()
        }
    }

    // MARK: - Files

    /// Leaves out anything already on the shelf.
    func add(_ urls: [URL], received: Bool = false) {
        var known = Set(items.map { $0.url.standardizedFileURL })
        var added: [Item] = []
        for url in urls where url.isFileURL && known.insert(url.standardizedFileURL).inserted {
            guard let bookmark = try? url.bookmarkData() else { continue }
            added.append(Item(id: UUID(), url: url, addedAt: .now, isReceived: received, bookmark: bookmark))
        }
        guard !added.isEmpty else { return }
        items += added
        save()
        onEvent?(.added)
    }

    /// Taken off the shelf from its menu, or with Clear: a promised file's
    /// copy goes to the Bin, in case it was the only one.
    func remove(_ ids: Set<Item.ID>) {
        remove(ids, discarding: .trash)
    }

    func clear() {
        remove(Set(items.map(\.id)))
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Asks where each file is now, following renames and moves, and drops
    /// the ones that have gone. The notch calls this as it opens.
    func refresh() {
        var isChanged = false
        let kept: [Item] = items.compactMap { item in
            guard let resolved = Self.resolve(item.bookmark) else {
                isChanged = true
                return nil
            }
            guard resolved.url != item.url || resolved.bookmark != item.bookmark else { return item }
            isChanged = true
            var moved = item
            moved.url = resolved.url
            moved.bookmark = resolved.bookmark
            return moved
        }
        guard isChanged else { return }
        let wasEmpty = items.isEmpty
        items = kept
        save()
        if !wasEmpty, items.isEmpty {
            onEvent?(.emptied)
        }
    }

    // MARK: - AirDrop

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        // MacCove has no windows in front of its own; without this, the
        // AirDrop picker opens behind the app you're in.
        NSApp.activate()
        service.perform(withItems: urls)
    }

    func airDropAll() {
        refresh()
        airDrop(items.map(\.url))
    }

    // MARK: - Dragging in

    /// From the notch, as a file drag comes near, goes over it and leaves.
    func setDragPhase(_ phase: DragPhase?) {
        guard phase != dragPhase else { return }
        dragPhase = phase
        if phase == nil {
            draggedNames = []
            draggedCount = 0
            dropZone = .shelf
        }
    }

    /// What the drag over the notch carries, once the notch can see it.
    func setDragContents(names: [String], count: Int) {
        if draggedNames != names {
            draggedNames = names
        }
        if draggedCount != count {
            draggedCount = count
        }
    }

    func setDropZone(_ zone: DropZone) {
        if dropZone != zone {
            dropZone = zone
        }
    }

    func endDrag() {
        setDragPhase(nil)
    }

    /// Saves what a drag promised into the shelf's folder, then hands the
    /// files on together, a moment after the last arrives.
    func receive(_ receivers: [NSFilePromiseReceiver], then handle: @escaping ([URL]) -> Void) {
        final class Batch {
            var urls: [URL] = []
            var delivery: Task<Void, Never>?
        }
        let batch = Batch()
        for receiver in receivers {
            let folder = Self.receivedFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { continue }
            // On the main queue, where the shelf lives.
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                guard error == nil else { return }
                batch.urls.append(url)
                batch.delivery?.cancel()
                batch.delivery = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    handle(batch.urls)
                    batch.urls = []
                }
            }
        }
    }

    // MARK: - Dragging out

    /// Picks up `items` from `view`, where `event`, the mouse down, began.
    func beginDrag(_ items: [Item], from view: NSView, event: NSEvent) {
        let source = dragSource ?? ShelfDragSource(shelf: self)
        dragSource = source
        source.begin(items, from: view, event: event)
    }

    fileprivate enum Discard {
        /// To the Bin, where it can be got back.
        case trash
        /// Gone: a copy of it is wherever it was just dragged.
        case delete
    }

    /// Dragged somewhere: off the shelf, and a promised file's copy with it,
    /// unless it moved there.
    fileprivate func removeDragged(_ ids: Set<Item.ID>) {
        remove(ids, discarding: .delete)
    }

    private func remove(_ ids: Set<Item.ID>, discarding discard: Discard) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        save()
        Self.discard(removed, discard)
        if items.isEmpty {
            onEvent?(.emptied)
        }
    }

    /// Only what's still in the shelf's own folder: a promised file dragged
    /// out with a move has gone on, and one already on disk is never touched.
    private static func discard(_ removed: [Item], _ discard: Discard) {
        let fileManager = FileManager.default
        let receivedPath = receivedFolder.standardizedFileURL.path(percentEncoded: false)
        for item in removed where item.isReceived {
            let folder = item.url.deletingLastPathComponent()
            guard folder.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false) == receivedPath else { continue }
            if fileManager.fileExists(atPath: item.url.path(percentEncoded: false)) {
                switch discard {
                case .trash: try? fileManager.trashItem(at: item.url, resultingItemURL: nil)
                case .delete: try? fileManager.removeItem(at: item.url)
                }
            }
            // The folder it was saved in, once it's empty.
            if (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    // MARK: - Keeping them

    nonisolated private struct Stored: Codable {
        let id: UUID
        let bookmark: Data
        let addedAt: Date
        let isReceived: Bool
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.itemsKey),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        items = stored.compactMap { stored in
            guard let resolved = Self.resolve(stored.bookmark) else { return nil }
            return Item(id: stored.id, url: resolved.url, addedAt: stored.addedAt, isReceived: stored.isReceived, bookmark: resolved.bookmark)
        }
        if items.count != stored.count || zip(items, stored).contains(where: { $0.bookmark != $1.bookmark }) {
            save()
        }
    }

    private func save() {
        let stored = items.map { Stored(id: $0.id, bookmark: $0.bookmark, addedAt: $0.addedAt, isReceived: $0.isReceived) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.itemsKey)
    }

    /// Where a bookmark leads now, with a fresh bookmark when the old one
    /// has gone stale; `nil` once the file is gone or in the Bin.
    private static func resolve(_ bookmark: Data) -> (url: URL, bookmark: Data)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              !url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { return nil }
        guard isStale, let fresh = try? url.bookmarkData() else { return (url, bookmark) }
        return (url, fresh)
    }

    // MARK: - Thumbnails

    /// The file as the Finder previews it, a picture or the first page, or
    /// else its icon.
    nonisolated static func thumbnail(of url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}

/// Carries files out of the shelf into any app, and takes them off it once
/// they've landed somewhere.
final class ShelfDragSource: NSObject, NSDraggingSource {
    private weak var shelf: FileShelf?
    private var dragged: Set<FileShelf.Item.ID> = []

    private static let imageSize = NSSize(width: 48, height: 48)
    /// How far each file in a pile sits from the one before.
    private static let pileOffset: CGFloat = 4

    init(shelf: FileShelf) {
        self.shelf = shelf
    }

    func begin(_ items: [FileShelf.Item], from view: NSView, event: NSEvent) {
        guard !items.isEmpty else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let size = Self.imageSize
        let draggingItems = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(index) * Self.pileOffset
            draggingItem.setDraggingFrame(
                NSRect(x: point.x - size.width / 2 + offset, y: point.y - size.height / 2 - offset, width: size.width, height: size.height),
                contents: NSWorkspace.shared.icon(forFile: item.url.path(percentEncoded: false))
            )
            return draggingItem
        }
        dragged = Set(items.map(\.id))
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .pile : .none
        // The notch's panel would otherwise take any drop under it, and
        // the open notch covers whatever's below the menu bar there.
        view.window?.ignoresMouseEvents = true
    }

    /// Like dragging from the Finder: a move on the same disk, a copy to
    /// another, Option for a copy anyway. Never back onto the notch.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let ids = dragged
        dragged = []
        guard !operation.isEmpty else { return }
        shelf?.removeDragged(ids)
    }
}

#if DEBUG
extension FileShelf {
    /// Files and a drag as given, for SwiftUI previews. Nothing is read
    /// from or saved to disk.
    static func preview(
        _ names: [String],
        dragPhase: DragPhase? = nil,
        dragged: [String] = [],
        dropZone: DropZone = .shelf
    ) -> FileShelf {
        let shelf = FileShelf(loadsSaved: false)
        shelf.items = names.map { name in
            Item(id: UUID(), url: URL(filePath: "/Users/Shared/\(name)"), addedAt: .now, isReceived: false, bookmark: Data())
        }
        shelf.dragPhase = dragPhase
        shelf.draggedNames = dragged
        shelf.draggedCount = dragged.count
        shelf.dropZone = dropZone
        return shelf
    }
}
#endif
