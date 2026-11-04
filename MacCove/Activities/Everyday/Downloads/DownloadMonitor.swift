//
//  DownloadMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit

/// Downloads into the Downloads folder, as the notch shows them: the
/// percentage while they come in, then a check once the last one is done.
///
/// Browsers publish each download's progress for the Finder to draw on its
/// icon. MacCove subscribes to that for the Downloads folder, so it sees
/// what Safari, Chrome and the browsers built on Chrome are fetching
/// without reading the folder itself: only each file's name, size and how
/// much of it has arrived.
@Observable
final class DownloadMonitor {
    enum Event {
        case started
        /// The last one running finished: shown without opening.
        case finished
        /// Cancelled, dismissed, or done showing.
        case ended
    }

    struct Download: Equatable, Identifiable {
        let id: UUID
        /// Where it will be once done, without the browser's `.download`
        /// or `.crdownload`.
        var url: URL
        /// The browser it's coming from, when that can be told.
        var source: String?
        var receivedBytes: Int64
        /// `nil` until the server says how big it is.
        var totalBytes: Int64?
        /// Smoothed over the last few seconds, `nil` until there's enough
        /// to go on.
        var bytesPerSecond: Double?
        var isFinished = false

        var name: String { url.lastPathComponent }

        var fraction: Double? {
            if isFinished { return 1 }
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(receivedBytes) / Double(totalBytes))
        }

        var secondsLeft: TimeInterval? {
            guard !isFinished, let totalBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
            return Double(max(0, totalBytes - receivedBytes)) / bytesPerSecond
        }
    }

    static let enabledKey = "DownloadsEnabled"

    /// On until it's turned off in Settings.
    private(set) var isEnabled = UserDefaults.standard.object(forKey: DownloadMonitor.enabledKey) as? Bool ?? true

    /// The downloads being shown, oldest first: those still running and
    /// those that finished while others ran. Empty when there's nothing.
    private(set) var downloads: [Download] = []

    /// Every one shown has finished.
    var isFinished: Bool {
        !downloads.isEmpty && downloads.allSatisfy(\.isFinished)
    }

    /// The one a finished pill is about: the last to finish.
    private(set) var lastFinished: Download?

    /// Between them all, `nil` while any has no known size.
    var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(total))
    }

    var receivedBytes: Int64 {
        downloads.reduce(0) { $0 + $1.receivedBytes }
    }

    var totalBytes: Int64? {
        var total: Int64 = 0
        for download in downloads {
            guard let bytes = download.isFinished ? download.receivedBytes : download.totalBytes else { return nil }
            total += bytes
        }
        return total
    }

    var bytesPerSecond: Double? {
        let speeds = downloads.filter { !$0.isFinished }.compactMap(\.bytesPerSecond)
        return speeds.isEmpty ? nil : speeds.reduce(0, +)
    }

    /// Until the slowest one is done, at the speed each is going.
    var secondsLeft: TimeInterval? {
        let running = downloads.filter { !$0.isFinished }
        guard !running.isEmpty else { return nil }
        let each = running.map(\.secondsLeft)
        guard each.allSatisfy({ $0 != nil }) else { return nil }
        return each.compactMap { $0 }.max()
    }

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the notch is open or under the cursor, when a finished
    /// download waits to leave until you're done with it.
    @ObservationIgnored var isInUse: () -> Bool = { false }

    @ObservationIgnored private var subscriber: Any?
    /// The browsers' progress, by the download it's for.
    @ObservationIgnored private var progresses: [UUID: Progress] = [:]
    /// Unpublished before the main thread heard it was published.
    @ObservationIgnored private var unpublishedIDs: Set<UUID> = []
    /// Published, but not yet saying what it is: Safari's arrive a moment
    /// before they name their file. Read again with the rest until they do.
    @ObservationIgnored private var unidentified: [UUID: (progress: Progress, since: Date)] = [:]
    /// Recent byte counts, for the speed.
    @ObservationIgnored private var samples: [UUID: [(date: Date, bytes: Int64)]] = [:]
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var finishedDismissal: Task<Void, Never>?
    /// Done showing, but kept while the notch was in use.
    @ObservationIgnored private var isDue = false

    /// How often the progress is read while something downloads.
    private static let pollInterval: Duration = .milliseconds(500)
    /// How far back the speed looks.
    private static let speedWindow: TimeInterval = 4
    /// How long a progress has to say what it is before it's let go.
    private static let identifyTimeout: TimeInterval = 5
    /// How long the check stays once the last one is done.
    private static let finishedDuration: Duration = .seconds(4)
    /// What browsers call a download until it's done.
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part"]
    /// Browsers built on Chrome, which all name their downloads
    /// `.crdownload`, in the order to guess them.
    private static let chromiumBrowsers: [(bundleIdentifier: String, name: String)] = [
        ("com.google.Chrome", "Chrome"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.operasoftware.Opera", "Opera"),
        ("org.chromium.Chromium", "Chromium"),
    ]

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard isEnabled, subscriber == nil else { return }
        subscriber = Self.subscribe(
            to: URL.downloadsDirectory,
            published: { @MainActor [weak self] id, progress in
                self?.published(id: id, progress: progress)
            },
            unpublished: { @MainActor [weak self] id in
                self?.unpublished(id: id)
            }
        )
    }

    /// Turned off: nothing more shows.
    func stop() {
        finishedDismissal?.cancel()
        isDue = false
        if let subscriber {
            Progress.removeSubscriber(subscriber)
        }
        subscriber = nil
        polling?.cancel()
        polling = nil
        progresses = [:]
        samples = [:]
        unpublishedIDs = []
        unidentified = [:]
        guard !downloads.isEmpty else { return }
        downloads = []
        lastFinished = nil
        onEvent?(.ended)
    }

    /// Leaves the notch. Anything still downloading carries on, and comes
    /// back with the next one to start.
    func dismiss() {
        guard !downloads.isEmpty else { return }
        finishedDismissal?.cancel()
        isDue = false
        let running = Set(progresses.keys)
        downloads = []
        lastFinished = nil
        // What's still running stays out of the notch: forgotten here, it
        // still finishes in the browser.
        for id in running {
            progresses[id] = nil
            samples[id] = nil
        }
        onEvent?(.ended)
    }

    /// The files selected in the Finder, those still coming in as the
    /// browser names them, or else the Downloads folder. Once they're all
    /// done, that's them seen to, so they leave.
    func showInFinder() {
        let finished = isFinished
        let files = downloads.compactMap { download in
            download.isFinished ? download.url : progresses[download.id].flatMap(Self.fileURL(of:))
        }
        if files.isEmpty {
            NSWorkspace.shared.open(URL.downloadsDirectory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
        if finished {
            dismiss()
        }
    }

    /// Opens the last file to finish in the app for it, and leaves. One
    /// that's gone since, moved or renamed, leaves the Downloads folder
    /// open instead: MacCove doesn't look inside it to find where.
    func openFinished() {
        guard let url = lastFinished?.url else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL.downloadsDirectory)
        }
        dismiss()
    }

    /// Takes the finished pill away, after `delay`, unless the notch is
    /// open or under the cursor; then it waits to be asked again.
    func leaveIfDue(after delay: Duration = .zero) {
        guard isDue, isFinished else {
            isDue = false
            return
        }
        finishedDismissal?.cancel()
        finishedDismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isDue, self.isFinished, !self.isInUse() else { return }
            self.isDue = false
            self.dismiss()
        }
    }

    // MARK: - From the browsers

    private func published(id: UUID, progress: Progress) {
        guard !unpublishedIDs.contains(id) else { return }
        switch Self.identify(progress) {
        case .download(let fileURL):
            admit(id: id, progress: progress, fileURL: fileURL)
        case .other:
            break
        case .unknown:
            unidentified[id] = (progress, .now)
            pollWhileRunning()
        }
    }

    /// Unidentified ones, again: shown once they say they're downloads,
    /// let go if they turn out to be something else or never say.
    private func identifyWaiting(at now: Date) {
        for (id, waiting) in unidentified {
            switch Self.identify(waiting.progress) {
            case .download(let fileURL):
                unidentified[id] = nil
                admit(id: id, progress: waiting.progress, fileURL: fileURL)
            case .other:
                unidentified[id] = nil
            case .unknown:
                if now.timeIntervalSince(waiting.since) >= Self.identifyTimeout {
                    unidentified[id] = nil
                }
            }
        }
    }

    private func admit(id: UUID, progress: Progress, fileURL: URL) {
        let isNewBatch = downloads.isEmpty || isFinished
        if isNewBatch {
            finishedDismissal?.cancel()
            isDue = false
            downloads = []
            lastFinished = nil
        }
        progresses[id] = progress
        downloads.append(Download(
            id: id,
            url: Self.finalURL(for: fileURL),
            source: Self.source(for: fileURL),
            receivedBytes: max(0, progress.completedUnitCount),
            totalBytes: Self.total(of: progress)
        ))
        pollWhileRunning()
        onEvent?(.started)
    }

    /// Done when everything arrived; anything else was cancelled or failed.
    private func unpublished(id: UUID) {
        // Gone before it said what it was: never shown.
        if unidentified.removeValue(forKey: id) != nil {
            return
        }
        guard let progress = progresses.removeValue(forKey: id) else {
            unpublishedIDs.insert(id)
            return
        }
        samples[id] = nil
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        let total = Self.total(of: progress)
        // A browser may let go a rounding error short of the end.
        let isComplete = !progress.isCancelled
            && (progress.fractionCompleted >= 0.999 || (total.map { progress.completedUnitCount >= $0 } ?? false))

        if isComplete {
            downloads[index].isFinished = true
            downloads[index].bytesPerSecond = nil
            if let total {
                downloads[index].receivedBytes = total
                downloads[index].totalBytes = total
            } else {
                downloads[index].receivedBytes = max(downloads[index].receivedBytes, progress.completedUnitCount)
            }
            if let url = Self.destination(of: progress) {
                downloads[index].url = url
            }
            lastFinished = downloads[index]
        } else {
            downloads.remove(at: index)
        }

        if downloads.isEmpty {
            lastFinished = nil
            onEvent?(.ended)
        } else if isFinished {
            onEvent?(.finished)
            finishedDismissal?.cancel()
            finishedDismissal = Task { [weak self] in
                try? await Task.sleep(for: Self.finishedDuration)
                guard !Task.isCancelled, let self else { return }
                self.isDue = true
                self.leaveIfDue()
            }
        }
    }

    /// The proxies the subscription hands over don't say when they change,
    /// so they're read twice a second while anything downloads.
    private func pollWhileRunning() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !self.progresses.isEmpty || !self.unidentified.isEmpty else { break }
                self.readProgress()
            }
            // Cancelled by `stop()`, which already let go of it, and may
            // have started another since.
            guard !Task.isCancelled else { return }
            self?.polling = nil
        }
    }

    private func readProgress() {
        let now = Date.now
        identifyWaiting(at: now)
        var updated = downloads
        for index in updated.indices {
            let id = updated[index].id
            guard !updated[index].isFinished, let progress = progresses[id] else { continue }
            let bytes = max(0, progress.completedUnitCount)
            updated[index].receivedBytes = bytes
            updated[index].totalBytes = Self.total(of: progress)
            // Chrome renames a download once it knows what to call it.
            if let url = Self.destination(of: progress) {
                updated[index].url = url
            }

            var recent = (samples[id] ?? []).filter { now.timeIntervalSince($0.date) <= Self.speedWindow }
            recent.append((now, bytes))
            samples[id] = recent
            if let first = recent.first, now.timeIntervalSince(first.date) >= 1 {
                updated[index].bytesPerSecond = Double(bytes - first.bytes) / now.timeIntervalSince(first.date)
            }
        }
        if updated != downloads {
            downloads = updated
        }
    }

    // MARK: - Helpers

    private enum Identity {
        case download(URL)
        /// Unzipping or copying into the folder publishes progress too.
        case other
        /// Not saying yet.
        case unknown
    }

    /// A download once it says it's downloading, or has a browser's
    /// partial name; something else once it says it's that.
    private static func identify(_ progress: Progress) -> Identity {
        guard let fileURL = fileURL(of: progress) else { return .unknown }
        let isPartial = partialExtensions.contains(fileURL.pathExtension.lowercased())
        switch operationKind(of: progress) {
        case .downloading?:
            return .download(fileURL)
        case nil:
            return isPartial ? .download(fileURL) : .unknown
        case _?:
            // Safari moves on to unzipping under the same name.
            return isPartial ? .download(fileURL) : .other
        }
    }

    /// Safari's proxies carry their file in their info a moment before
    /// `fileURL` says so, so that's read too.
    private static func fileURL(of progress: Progress) -> URL? {
        progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL
    }

    private static func operationKind(of progress: Progress) -> Progress.FileOperationKind? {
        if let kind = progress.fileOperationKind {
            return kind
        }
        return (progress.userInfo[.fileOperationKindKey] as? String).map { Progress.FileOperationKind(rawValue: $0) }
    }

    /// Where the file ends up. Safari opens "safe" downloads once they're
    /// in, unzipping an archive and throwing it away, so a zip it's
    /// unzipping ends up as the folder beside it.
    private static func destination(of progress: Progress) -> URL? {
        guard let fileURL = fileURL(of: progress) else { return nil }
        let url = finalURL(for: fileURL)
        let unzipping = Progress.FileOperationKind.decompressingAfterDownloading
        // Safari has been seen to say so in `kind` rather than its own key.
        let isUnzipping = operationKind(of: progress) == unzipping || progress.kind?.rawValue == unzipping.rawValue
        return isUnzipping && url.pathExtension.lowercased() == "zip" ? url.deletingPathExtension() : url
    }

    private static func total(of progress: Progress) -> Int64? {
        let total = progress.totalUnitCount
        return total > 0 && !progress.isIndeterminate ? total : nil
    }

    /// `Movie.mov.download` and `Movie.mov.crdownload` are `Movie.mov`.
    private static func finalURL(for fileURL: URL) -> URL {
        partialExtensions.contains(fileURL.pathExtension.lowercased()) ? fileURL.deletingPathExtension() : fileURL
    }

    /// Safari names its downloads `.download`. The browsers built on Chrome
    /// all use `.crdownload`, so it's whichever of them is running.
    private static func source(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "download":
            return "Safari"
        case "crdownload":
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            return chromiumBrowsers.first { running.contains($0.bundleIdentifier) }?.name
        default:
            return nil
        }
    }

    /// The handlers run on whatever thread the progress arrives on, so
    /// they're made away from the main actor and hop back to it, in the
    /// order they came.
    nonisolated private static func subscribe(
        to folder: URL,
        published: @escaping @MainActor @Sendable (UUID, Progress) -> Void,
        unpublished: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> Any {
        Progress.addSubscriber(forFileURL: folder) { progress in
            let id = UUID()
            let box = ProgressBox(progress: progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { published(id, box.progress) }
            }
            return {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { unpublished(id) }
                }
            }
        }
    }
}

/// A browser's progress, carried over to the main actor. Progress objects
/// are safe to read from any thread.
nonisolated private struct ProgressBox: @unchecked Sendable {
    let progress: Progress
}

#if DEBUG
extension DownloadMonitor {
    /// Downloads that stay as given, for SwiftUI previews.
    static func preview(_ downloads: [Download]) -> DownloadMonitor {
        let monitor = DownloadMonitor()
        monitor.downloads = downloads
        monitor.lastFinished = downloads.last(where: \.isFinished)
        return monitor
    }
}
#endif
