import AppKit

/// What Xcode is doing, as the island shows it: a build, a test run or the
/// app running, each in progress and then, for builds and tests, failed or
/// succeeded. A run that quits unexpectedly counts as failed.
///
/// Xcode doesn't tell other apps about any of this, so it relies on its
/// Behaviors (Settings › Behaviors), which can run a script as a build or
/// test run starts, succeeds or fails, and as the app starts running,
/// completes or exits unexpectedly. The scripts MacCove installs for them
/// (see `XcodeBehaviorScripts`) open a maccove://xcode/… URL, which lands
/// in `handle(_:)`. The rest comes from asking Xcode for the scheme and run
/// destination, and from the logs and test results it leaves in
/// DerivedData.
///
/// Xcode reports no progress, so the ring is the time so far against the
/// last successful build or test run of the same scheme.
@Observable
final class XcodeBuildMonitor {
    enum Event {
        case started
        case failed
        case succeeded
        /// Dismissed, stopped, or found to have ended without a result.
        case ended
    }

    enum Action: String {
        case build
        case test
        case run
    }

    enum Phase: Equatable {
        case inProgress
        /// `errorCount` stays `nil` until it's been read from the logs, and
        /// `errors` holds only the first few. For a test run, they're the
        /// failed tests.
        case failed(errors: [XcodeBuildIssue], errorCount: Int?, warningCount: Int?)
        case succeeded(warningCount: Int?)
    }

    /// A build, a test run or a run of the app.
    struct Build: Equatable {
        let id = UUID()
        var action: Action
        /// The workspace or project, as `XcodeBuildLogs.normalizedPath`
        /// gives it.
        var workspacePath: String?
        /// The same workspace as Xcode reports it, for sending it commands.
        var documentPath: String?
        var scheme: String?
        var destination: String?
        var configuration: String?
        /// `nil` when only the result was reported.
        var startedAt: Date?
        var finishedAt: Date?
        /// How long the last successful build or test run of this scheme
        /// took. Never kept for runs, which take as long as you like.
        var expectedDuration: TimeInterval?
        /// All the tests in a finished test run.
        var testCount: Int?
        var phase: Phase

        var name: String {
            scheme ?? workspacePath.map { XcodeBuildLogs.displayName(workspacePath: $0) } ?? "Xcode"
        }

        var duration: TimeInterval? {
            guard let startedAt, let finishedAt else { return nil }
            return finishedAt.timeIntervalSince(startedAt)
        }
    }

    /// What's being shown, `nil` once it has left the island.
    private(set) var build: Build?

    @ObservationIgnored var onEvent: ((Event) -> Void)?

    /// Errors or failed tests listed in the island; the rest are left to
    /// Xcode.
    static let shownErrorLimit = 2
    /// How often a build or test run is checked for its end, in case Xcode
    /// never reports a result (see `watchForEnd`).
    private static let watchInterval: Duration = .seconds(3)
    private static let durationsKey = "XcodeBuildDurations"

    @ObservationIgnored private let scripting = XcodeScripting()
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var resultTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    /// Returns whether the URL was one of the Xcode scripts'. Builds have
    /// the bare event ("started"), as the first scripts did; tests and runs
    /// have theirs in front ("test-failed").
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "maccove", url.host() == "xcode" else { return false }
        let workspace = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "workspace" }?.value
            .flatMap { $0.isEmpty ? nil : XcodeBuildLogs.normalizedPath($0) }
        switch url.lastPathComponent {
        case "started": begin(.build, workspacePath: workspace)
        case "succeeded": finish(.build, succeeded: true, workspacePath: workspace)
        case "failed": finish(.build, succeeded: false, workspacePath: workspace)
        case "test-started": begin(.test, workspacePath: workspace)
        case "test-succeeded": finish(.test, succeeded: true, workspacePath: workspace)
        case "test-failed": finish(.test, succeeded: false, workspacePath: workspace)
        case "run-started": begin(.run, workspacePath: workspace)
        case "run-crashed": finish(.run, succeeded: false, workspacePath: workspace)
        case "run-completed": runCompleted()
        default: break
        }
        return true
    }

    func dismiss() {
        guard build != nil else { return }
        cancelTasks()
        build = nil
        onEvent?(.ended)
    }

    /// Stops it in Xcode. Xcode reports no result for a stopped build or
    /// test run, so it leaves the island straight away.
    func stop() {
        XcodeCommand.stop.send(toDocumentAt: build?.documentPath)
        dismiss()
    }

    /// Runs the scheme just built. The build that comes first reports
    /// itself and takes this one's place.
    func run() {
        XcodeCommand.run.send(toDocumentAt: build?.documentPath)
    }

    /// Tests the scheme again, which likewise takes this one's place.
    func test() {
        XcodeCommand.test.send(toDocumentAt: build?.documentPath)
    }

    func openInXcode() {
        XcodeCommand.open(workspacePath: build?.workspacePath)
    }

    // MARK: - Reports from Xcode

    /// Whatever starts replaces whatever was showing, finished or not: ⌘R
    /// and ⌘U report the build first, then the run or tests take over.
    private func begin(_ action: Action, workspacePath: String?) {
        cancelTasks()
        let started = Build(action: action, workspacePath: workspacePath, startedAt: .now, phase: .inProgress)
        build = started
        onEvent?(.started)
        detailsTask = Task { [weak self] in
            await self?.loadDetails(of: started.id)
        }
        watchTask = Task { [weak self] in
            await self?.watchForEnd(of: started.id)
        }
    }

    /// Also shows a result reported without a start, as when the Starts
    /// behavior isn't set up.
    private func finish(_ action: Action, succeeded: Bool, workspacePath: String?) {
        watchTask?.cancel()
        resultTask?.cancel()
        let current = build?.action == action ? build : nil
        var finished = current ?? Build(action: action, workspacePath: workspacePath, phase: .inProgress)
        finished.finishedAt = .now
        finished.phase = succeeded
            ? .succeeded(warningCount: nil)
            : .failed(errors: [], errorCount: nil, warningCount: nil)
        build = finished
        if succeeded {
            recordDuration(of: finished)
        }
        onEvent?(succeeded ? .succeeded : .failed)

        if current == nil {
            detailsTask?.cancel()
            detailsTask = Task { [weak self] in
                await self?.loadDetails(of: finished.id)
            }
        }
        resultTask = Task { [weak self] in
            await self?.loadResult(of: finished.id)
        }
    }

    /// A run that ends normally, or is stopped in Xcode, just leaves. One
    /// that has already crashed stays until it's dismissed.
    private func runCompleted() {
        guard build?.action == .run, build?.phase == .inProgress else { return }
        dismiss()
    }

    // MARK: - Details

    /// The scheme, run destination and configuration, from Xcode and the
    /// scheme's file.
    private func loadDetails(of id: Build.ID) async {
        guard let workspace = await scripting.workspace(at: build?.workspacePath),
              var updated = build, updated.id == id else { return }
        updated.documentPath = workspace.path
        updated.workspacePath = updated.workspacePath ?? workspace.path.map { XcodeBuildLogs.normalizedPath($0) }
        updated.scheme = workspace.scheme ?? updated.scheme
        updated.destination = workspace.destination
        if let path = updated.workspacePath, let scheme = updated.scheme {
            updated.configuration = await XcodeBuildLogs.configuration(workspacePath: path, scheme: scheme)
        }
        guard !Task.isCancelled, var current = build, current.id == id else { return }
        current.documentPath = updated.documentPath
        current.workspacePath = updated.workspacePath
        current.scheme = updated.scheme
        current.destination = updated.destination
        current.configuration = updated.configuration
        current.expectedDuration = lastDuration(of: current)
        build = current
        // Quicker than the round trip to Xcode, so it has finished already.
        if case .succeeded = current.phase {
            recordDuration(of: current)
        }
    }

    /// The counts, and the first errors or failed tests, from the logs and
    /// test results. Xcode may still be writing them as the behavior runs,
    /// so this tries a few times.
    private func loadResult(of id: Build.ID) async {
        guard let finished = build, finished.id == id else { return }
        // Without a start, anything from the last few hours.
        let since = finished.startedAt ?? (finished.finishedAt ?? .now).addingTimeInterval(-3 * 60 * 60)
        switch finished.action {
        case .build:
            await loadBuildResult(of: id, since: since)
        case .test:
            await loadTestResult(of: id, since: since)
        case .run:
            // A crash leaves nothing MacCove can read.
            break
        }
    }

    private func loadBuildResult(of id: Build.ID, since: Date) async {
        guard let finished = build else { return }
        var entry: XcodeBuildLogs.Entry?
        for delay in [0, 0.5, 1, 2] {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            entry = await XcodeBuildLogs.latestEntry(workspacePath: finished.workspacePath, since: since)
            if entry != nil { break }
        }
        guard let entry else { return }

        var errors: [XcodeBuildIssue] = []
        var errorCount = entry.errorCount
        if case .failed = finished.phase {
            let parsed = await XcodeBuildLogs.errors(in: entry, limit: Self.shownErrorLimit)
            errors = parsed.first
            errorCount = max(errorCount, parsed.total)
        }
        guard !Task.isCancelled, var current = build, current.id == id else { return }
        current.scheme = current.scheme ?? entry.scheme
        switch current.phase {
        case .failed:
            current.phase = .failed(errors: errors, errorCount: errorCount, warningCount: entry.warningCount)
        case .succeeded:
            current.phase = .succeeded(warningCount: entry.warningCount)
        case .inProgress:
            break
        }
        build = current
    }

    /// Test results take a moment longer to close up than build logs.
    private func loadTestResult(of id: Build.ID, since: Date) async {
        guard let finished = build else { return }
        var summary: XcodeBuildLogs.TestSummary?
        for delay in [0, 0.5, 1, 2, 4] {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            summary = await XcodeBuildLogs.latestTestSummary(
                workspacePath: finished.workspacePath,
                since: since,
                failureLimit: Self.shownErrorLimit
            )
            if summary?.isFinished == true { break }
        }
        guard let summary, !Task.isCancelled, var current = build, current.id == id else { return }
        current.testCount = summary.total
        switch current.phase {
        case .failed:
            current.phase = .failed(errors: summary.failures, errorCount: summary.failed, warningCount: nil)
        case .succeeded, .inProgress:
            break
        }
        build = current
    }

    /// Xcode has no behavior for a build or test run that's stopped, so
    /// while one goes on its logs are checked every few seconds. One that
    /// has ended without a Succeeds or Fails report (stopped in Xcode, or
    /// those behaviors aren't set up) finishes from what its log says, or
    /// just leaves. A run ends through its own Completes behavior; here it
    /// only leaves with Xcode.
    private func watchForEnd(of id: Build.ID) async {
        guard let startedAt = build?.startedAt, let action = build?.action else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.watchInterval)
            guard !Task.isCancelled, let current = build, current.id == id, current.phase == .inProgress else { return }

            let isXcodeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: XcodeScripting.bundleIdentifier).isEmpty
            guard isXcodeRunning, Date.now.timeIntervalSince(startedAt) < Self.maxDuration(of: action) else {
                dismiss()
                return
            }
            guard let succeeded = await endedResult(of: current, since: startedAt) else { continue }
            // Give the Succeeds or Fails behavior a moment to report first.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, build?.id == id, build?.phase == .inProgress else { return }
            if let succeeded {
                finish(action, succeeded: succeeded, workspacePath: current.workspacePath)
            } else {
                dismiss()
            }
            return
        }
    }

    /// `nil` while it's still going; then whether it succeeded, or `nil`
    /// inside when there's no telling (a stopped build).
    private func endedResult(of current: Build, since startedAt: Date) async -> Bool?? {
        switch current.action {
        case .build:
            guard let entry = await XcodeBuildLogs.latestEntry(workspacePath: current.workspacePath, since: startedAt) else {
                return nil
            }
            if entry.errorCount > 0 { return .some(false) }
            return entry.succeeded ? .some(true) : .some(nil)
        case .test:
            guard let summary = await XcodeBuildLogs.latestTestSummary(
                workspacePath: current.workspacePath,
                since: startedAt,
                failureLimit: 0
            ), summary.isFinished else { return nil }
            return .some(summary.failed == 0)
        case .run:
            return nil
        }
    }

    /// Longer than this, it's assumed to have ended unnoticed. A run goes on
    /// as long as Xcode does.
    private static func maxDuration(of action: Action) -> TimeInterval {
        switch action {
        case .build: 30 * 60
        case .test: 3 * 60 * 60
        case .run: .infinity
        }
    }

    private func cancelTasks() {
        detailsTask?.cancel()
        resultTask?.cancel()
        watchTask?.cancel()
    }

    // MARK: - Durations

    /// Per action, workspace and scheme, kept across launches. Builds keep
    /// the keys they had before tests were timed too.
    private func durationKey(of build: Build) -> String? {
        guard build.action != .run, let scheme = build.scheme else { return nil }
        let key = "\(build.workspacePath ?? "")|\(scheme)"
        return build.action == .build ? key : "\(build.action.rawValue)|\(key)"
    }

    private func lastDuration(of build: Build) -> TimeInterval? {
        guard let key = durationKey(of: build) else { return nil }
        return UserDefaults.standard.dictionary(forKey: Self.durationsKey)?[key] as? TimeInterval
    }

    private func recordDuration(of build: Build) {
        guard let key = durationKey(of: build), let duration = build.duration else { return }
        var durations = UserDefaults.standard.dictionary(forKey: Self.durationsKey) ?? [:]
        durations[key] = duration
        UserDefaults.standard.set(durations, forKey: Self.durationsKey)
    }
}

extension XcodeBuildMonitor.Build: Identifiable {}

#if DEBUG
extension XcodeBuildMonitor {
    /// A build that stays as given, for SwiftUI previews.
    static func preview(_ build: Build) -> XcodeBuildMonitor {
        let monitor = XcodeBuildMonitor()
        monitor.build = build
        return monitor
    }
}
#endif
