//
//  XcodeBuildMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

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

    /// The setup guide Connect Xcode hands off to, so the steps stay in
    /// view while Xcode's Settings window covers MacCove's. It takes the
    /// notch's Xcode place while it's there, ahead of any build.
    struct Guide: Equatable {
        /// Shown in the welcome's card, which has the notch's place: it
        /// stays open there until it's closed with Done, rather than
        /// shrinking to the pill or leaving by itself.
        var staysOpen = false
        /// On the first step: getting to Behaviors in Xcode's Settings,
        /// before any events. Every guide starts here.
        var isAtStart = true
        /// Groups passed over with Skip.
        var skipped: Set<String> = []
        /// macOS is asking to let MacCove control Xcode, after the first
        /// script ran: the guide opens beside the prompt to explain it.
        var isAsking = false
        /// The event that ran last, shown while asking.
        var lastEvent: String?
    }

    /// What's being shown, `nil` once it has left the island.
    private(set) var build: Build?
    private(set) var guide: Guide?

    /// In the notch: a build, test run or run, or the setup guide.
    var isShown: Bool {
        build != nil || guide != nil
    }

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
    @ObservationIgnored private var guideTask: Task<Void, Never>?
    @ObservationIgnored private var guideWatch: Task<Void, Never>?

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
        guideHeard(url.lastPathComponent)
        return true
    }

    // MARK: - Setup guide

    var setup: XcodeSetupProgress { .shared }

    /// The group the guide is on: the first with an event not added yet,
    /// unless it was skipped. `nil` once there's nothing left to do.
    var guideGroup: String? {
        guard let guide else { return nil }
        return XcodeBehaviorScripts.groups.first { group in
            !guide.skipped.contains(group) && !setup.isGroupComplete(group)
        }
    }

    func startGuide(staysOpen: Bool = false) {
        guideTask?.cancel()
        let wasShown = isShown
        setup.refreshBehaviors()
        guide = Guide(staysOpen: staysOpen)
        watchBehaviors()
        if !wasShown {
            onEvent?(.started)
        }
        // Open for a moment, so it's seen, then the pill counts.
        onEvent?(.failed)
        if guideGroup == nil {
            leaveGuideSoon()
        }
    }

    /// The welcome has folded away: an unfinished guide carries on in the
    /// notch like any other.
    func releaseGuide() {
        guard guide?.staysOpen == true else { return }
        guide?.staysOpen = false
        onEvent?(.failed)
        if guideGroup == nil {
            leaveGuideSoon()
        }
    }

    func endGuide() {
        guideTask?.cancel()
        guideWatch?.cancel()
        guard guide != nil else { return }
        guide = nil
        if build == nil {
            onEvent?(.ended)
        }
    }

    /// Xcode saves its Behaviors as they change, so each ticks off as
    /// it's added, before Xcode has run it. Adding one also means you're
    /// past the first step.
    private func watchBehaviors() {
        guideWatch?.cancel()
        guideWatch = Task { [weak self] in
            var last = self?.setup.added
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self, self.guide != nil else { return }
                self.setup.refreshBehaviors()
                guard self.setup.added != last else { continue }
                last = self.setup.added
                self.guide?.isAtStart = false
                if self.guideGroup == nil, self.guide?.isAsking != true {
                    self.leaveGuideSoon()
                }
            }
        }
    }

    /// Past the first step, to the events.
    func continueGuide() {
        guide?.isAtStart = false
    }

    func skip(_ group: String) {
        guide?.skipped.insert(group)
        if guideGroup == nil {
            leaveGuideSoon()
        }
    }

    /// While the guide's up, explains the prompt that the first script to
    /// run brings up.
    private func guideHeard(_ event: String) {
        guard guide != nil else { return }
        // A script ran, so Behaviors is open already.
        guide?.isAtStart = false
        guideTask?.cancel()
        guideTask = Task { [weak self] in
            await self?.explainPromptIfAsked(after: event)
        }
    }

    /// Asking for the scheme's name is what brings the prompt up, and macOS
    /// keeps it Not Asked until it's answered.
    private func explainPromptIfAsked(after event: String) async {
        await setup.refreshControl()
        guard setup.isXcodeOpen, setup.control == .notAsked, guide != nil else {
            guide?.isAsking = false
            finishGuideIfDone()
            return
        }
        guide?.isAsking = true
        guide?.lastEvent = event
        // Opens by itself, beside macOS's prompt.
        onEvent?(.failed)
        // Up to a minute for an answer.
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, guide != nil else { return }
            await setup.refreshControl()
            if setup.control != .notAsked { break }
        }
        guide?.isAsking = false
        finishGuideIfDone()
    }

    private func finishGuideIfDone() {
        if guide != nil, guideGroup == nil {
            leaveGuideSoon()
        }
    }

    /// All set: a check, then it leaves.
    private func leaveGuideSoon() {
        // In the welcome, Done closes it.
        guard guide?.staysOpen != true else { return }
        guideTask?.cancel()
        guideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.endGuide()
        }
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
