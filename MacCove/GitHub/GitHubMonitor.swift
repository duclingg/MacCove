import AppKit

/// Your pull requests and review requests on GitHub, as the notch shows
/// them: checks running, a check failed, ready to merge, or someone asking
/// for your review.
///
/// Polls GitHub's GraphQL API every 30 seconds while checks are running
/// and every minute otherwise; there's no webhook to wait on. In between,
/// every 10 seconds, it asks GitHub whether your pull requests, their
/// checks or the open pull requests of their repositories have changed,
/// which costs nothing while they haven't, and polls straight away when
/// they have. After a push it polls every few seconds until the checks
/// appear. Only things that change while MacCove runs show up: what was
/// already failed, ready or waiting on you when it started is taken as
/// seen.
@Observable
final class GitHubMonitor {
    enum Event {
        /// Something new to show, or what's shown moved on.
        case started
        /// A check failed: opens by itself.
        case failed
        /// Nothing left to show.
        case ended
    }

    enum Phase: String {
        case running
        case failed
        /// Every check passed, but it still waits on a review, a conflict
        /// or being a draft. Shows for a moment, then leaves.
        case passed
        /// Every check passed and nothing else stands in the way.
        case ready
        /// Someone asked for your review.
        case review
    }

    struct Activity: Equatable, Identifiable {
        var pullRequest: GitHubPullRequest
        var phase: Phase

        var id: String { pullRequest.id }

        /// One for each pull request, commit and phase, so a dismissed
        /// failure comes back for a new commit, or a re-run that fails again.
        var key: String {
            phase == .review ? "\(id)@review" : "\(id)@\(pullRequest.headSHA ?? "")@\(phase.rawValue)"
        }
    }

    /// What's shown, `nil` when there's nothing.
    private(set) var activity: Activity?
    /// The account signed in, once GitHub has said.
    private(set) var login: String?
    /// The token stopped working; Connect GitHub asks for another.
    private(set) var needsSignIn = false
    /// Merge or Re-run Failed is on its way.
    private(set) var isActing = false

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the notch is open or under the cursor, when a passed result
    /// waits to leave until you're done with it.
    @ObservationIgnored var isInUse: () -> Bool = { false }
    /// Where the token comes from; swapped out by previews.
    @ObservationIgnored var tokenProvider: () async -> String? = { await GitHubSetup.token() }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// The last ETag of each REST resource watched for changes.
    @ObservationIgnored private var etags: [String: String] = [:]
    /// Each pull request's head commit, and when a new one was first seen.
    @ObservationIgnored private var heads: [String: (sha: String, seenAt: Date)] = [:]
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var latest: GitHubSnapshot?
    /// Each pull request's last key, to tell what changed between polls.
    @ObservationIgnored private var lastKeys: [String: String] = [:]
    @ObservationIgnored private var changedAt: [String: Date] = [:]
    @ObservationIgnored private var dismissed: Set<String> = []
    /// Failures seen since the last poll, which may open by themselves.
    @ObservationIgnored private var newFailures: Set<String> = []
    @ObservationIgnored private var hasBaseline = false
    /// Takes away a passed result after a moment.
    @ObservationIgnored private var passedDismissal: Task<Void, Never>?
    @ObservationIgnored private var duePassedKey: String?

    private static let activeInterval: Duration = .seconds(30)
    private static let idleInterval: Duration = .seconds(60)
    /// After a network error, rather than hammering away.
    private static let retryInterval: Duration = .seconds(120)
    /// Between asking whether anything changed.
    private static let watchInterval: Duration = .seconds(10)
    /// Right after a push, while GitHub queues the checks.
    private static let expectingInterval: Duration = .seconds(5)
    /// How long after a push to keep looking for its checks.
    private static let expectingWindow: TimeInterval = 120
    private static let passedDuration: Duration = .seconds(6)

    // MARK: - Polling

    func start() {
        guard pollTask == nil else { return }
        poll(after: .zero)
        watch()
    }

    /// Signed out: nothing more shows.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        watchTask?.cancel()
        watchTask = nil
        etags = [:]
        heads = [:]
        token = nil
        latest = nil
        login = nil
        needsSignIn = false
        lastKeys = [:]
        changedAt = [:]
        dismissed = []
        hasBaseline = false
        update()
    }

    /// After signing in again or picking other repositories.
    func restart() {
        stop()
        start()
    }

    private func poll(after delay: Duration) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var delay = delay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                guard let next = await self.fetch() else {
                    // A cancelled poll has already been replaced.
                    if !Task.isCancelled {
                        self.pollTask = nil
                    }
                    return
                }
                delay = next
            }
        }
    }

    /// One poll. Returns when to poll next, `nil` to stop. A token GitHub
    /// turns down is asked for once more, in case `gh` has a newer one.
    private func fetch() async -> Duration? {
        for attempt in 0 ..< 2 {
            guard let token = await currentToken(refresh: attempt > 0) else {
                // Signed out, or the CLI has no token any more.
                if GitHubSetup.source != nil {
                    needsSignIn = true
                }
                return nil
            }
            do {
                let snapshot = try await GitHubAPI(token: token).snapshot()
                guard !Task.isCancelled else { return nil }
                needsSignIn = false
                apply(snapshot)
                let isRunning = snapshot.authored.contains { Self.phase(of: $0) == .running }
                if isRunning { return Self.activeInterval }
                return isExpectingChecks(in: snapshot) ? Self.expectingInterval : Self.idleInterval
            } catch GitHubAPI.Failure.unauthorized {
                continue
            } catch {
                return Task.isCancelled ? nil : Self.retryInterval
            }
        }
        needsSignIn = true
        return nil
    }

    /// A pull request of yours with a new commit, or new altogether, whose
    /// checks haven't appeared yet.
    private func isExpectingChecks(in snapshot: GitHubSnapshot) -> Bool {
        snapshot.authored.filter(isWatched).contains { pullRequest in
            guard pullRequest.checks.isEmpty, let head = heads[pullRequest.id] else { return false }
            return Date.now.timeIntervalSince(head.seenAt) < Self.expectingWindow
        }
    }

    // MARK: - Watching for changes

    private func watch() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard !Task.isCancelled, let self else { return }
                if await self.hasChanged(), !Task.isCancelled {
                    self.poll(after: .zero)
                }
            }
        }
    }

    /// Your pull requests, for a push; the checks on their latest commits,
    /// for one finishing or being re-run from GitHub; and the open pull
    /// requests of their repositories and the ones picked, for a new one.
    private var watchedPaths: [String] {
        guard let latest else { return [] }
        let mine = latest.authored.filter(isWatched)
        var paths = mine.map { "repos/\($0.repository)/pulls/\($0.number)" }
        for pullRequest in mine {
            if let sha = pullRequest.headSHA {
                paths.append("repos/\(pullRequest.repository)/commits/\(sha)/check-runs?per_page=100")
            }
        }
        let repositories = Set(mine.map(\.repository)).union(GitHubSetup.repositories)
        paths += repositories.sorted().map { "repos/\($0)/pulls?state=open&sort=created&direction=desc&per_page=1" }
        return paths
    }

    /// Whether anything watched has changed since it was last asked about.
    /// The first answer for each only sets its ETag. Errors are left for
    /// the next poll to deal with.
    private func hasChanged() async -> Bool {
        guard !needsSignIn, let token else { return false }
        let api = GitHubAPI(token: token)
        let paths = watchedPaths
        var hasChanged = false
        for path in paths {
            guard !Task.isCancelled else { return false }
            guard let tag = try? await api.changeTag(of: path, since: etags[path]) else { continue }
            if etags[path] != nil {
                hasChanged = true
            }
            etags[path] = tag
        }
        etags = etags.filter { paths.contains($0.key) }
        return hasChanged
    }

    /// Kept between polls, so `gh` isn't run every minute.
    private func currentToken(refresh: Bool = false) async -> String? {
        if refresh || token == nil {
            token = await tokenProvider()
        }
        return token
    }

    // MARK: - What to show

    /// Where a pull request of yours stands, `nil` when there's nothing to
    /// say: no checks, or they haven't started.
    static func phase(of pullRequest: GitHubPullRequest) -> Phase? {
        let checks = pullRequest.checks
        guard !checks.isEmpty else { return nil }
        if checks.contains(where: { $0.status == .running }) { return .running }
        if checks.contains(where: { $0.status == .failed }) { return .failed }
        let isBlocked = pullRequest.isDraft
            || pullRequest.mergeable == "CONFLICTING"
            || pullRequest.reviewDecision == "REVIEW_REQUIRED"
            || pullRequest.reviewDecision == "CHANGES_REQUESTED"
        return isBlocked ? .passed : .ready
    }

    private func isWatched(_ pullRequest: GitHubPullRequest) -> Bool {
        let repositories = GitHubSetup.repositories
        return repositories.isEmpty || repositories.contains { $0.caseInsensitiveCompare(pullRequest.repository) == .orderedSame }
    }

    private func apply(_ snapshot: GitHubSnapshot) {
        latest = snapshot
        login = snapshot.login
        // New commits since MacCove started are expecting checks.
        var heads: [String: (sha: String, seenAt: Date)] = [:]
        for pullRequest in snapshot.authored {
            guard let sha = pullRequest.headSHA else { continue }
            if let known = self.heads[pullRequest.id], known.sha == sha {
                heads[pullRequest.id] = known
            } else {
                heads[pullRequest.id] = (sha, hasBaseline ? .now : .distantPast)
            }
        }
        self.heads = heads
        var seen: Set<String> = []
        for activity in activities(in: snapshot) {
            let key = activity.key
            seen.insert(activity.id)
            guard lastKeys[activity.id] != key else { continue }
            lastKeys[activity.id] = key
            changedAt[activity.id] = .now
            if !hasBaseline, activity.phase != .running {
                // Already like this when MacCove started.
                dismissed.insert(key)
            } else if activity.phase == .failed {
                newFailures.insert(key)
            }
        }
        // Closed, merged, or no longer asking for you.
        for id in lastKeys.keys where !seen.contains(id) {
            lastKeys[id] = nil
            changedAt[id] = nil
        }
        let current = Set(lastKeys.values)
        dismissed.formIntersection(current)
        hasBaseline = true
        update()
    }

    /// Every pull request with something to say, in the repositories
    /// watched. Your own come first, should you have asked yourself.
    private func activities(in snapshot: GitHubSnapshot) -> [Activity] {
        var activities = snapshot.authored.filter(isWatched).compactMap { pullRequest in
            Self.phase(of: pullRequest).map { Activity(pullRequest: pullRequest, phase: $0) }
        }
        let authored = Set(snapshot.authored.map(\.id))
        activities += snapshot.reviewRequested
            .filter { isWatched($0) && !authored.contains($0.id) }
            .map { Activity(pullRequest: $0, phase: .review) }
        return activities
    }

    private static func priority(_ phase: Phase) -> Int {
        switch phase {
        case .failed: 0
        case .running: 1
        case .ready: 2
        case .passed: 3
        case .review: 4
        }
    }

    /// Picks the one to show: a failure first, then checks running, then
    /// the newest of the rest. Tells the notch when that changes.
    private func update() {
        let candidates = latest.map(activities(in:))?.filter { !dismissed.contains($0.key) } ?? []
        let next = candidates.min { lhs, rhs in
            let left = Self.priority(lhs.phase), right = Self.priority(rhs.phase)
            if left != right { return left < right }
            return (changedAt[lhs.id] ?? .distantPast) > (changedAt[rhs.id] ?? .distantPast)
        }
        let previous = activity
        activity = next
        defer { newFailures.removeAll() }

        guard let next else {
            if previous != nil { onEvent?(.ended) }
            return
        }
        guard previous?.key != next.key else { return }
        if next.phase == .passed {
            scheduleLeaving(next.key)
        }
        onEvent?(next.phase == .failed && newFailures.contains(next.key) ? .failed : .started)
    }

    // MARK: - Buttons

    /// Off the notch until it changes again.
    func dismiss() {
        guard let activity else { return }
        dismissed.insert(activity.key)
        update()
    }

    func openPullRequest() {
        guard let activity else { return }
        NSWorkspace.shared.open(activity.pullRequest.url)
    }

    /// View, Open Pull Request: once it's open in the browser, the notch
    /// has done its job.
    func openAndDismiss() {
        openPullRequest()
        dismiss()
    }

    /// The first failed check's page, which has its logs, or the pull
    /// request's checks.
    func viewLogs() {
        guard let activity else { return }
        let failed = activity.pullRequest.checks.first { $0.status == .failed }
        let url = failed?.url ?? activity.pullRequest.url.appending(path: "checks")
        NSWorkspace.shared.open(url)
        dismiss()
    }

    var canRerun: Bool {
        guard let activity, activity.phase == .failed else { return false }
        return !Self.failedRuns(of: activity.pullRequest).isEmpty
    }

    /// Re-runs the failed jobs of each GitHub Actions run that failed. The
    /// pill goes back to the ring straight away, and the next poll, a few
    /// seconds on, catches up with what GitHub is doing.
    func rerunFailed() {
        guard let activity, !isActing else { return }
        let runs = Self.failedRuns(of: activity.pullRequest)
        guard !runs.isEmpty else { return }
        isActing = true
        Task {
            defer { isActing = false }
            guard let token = await currentToken() else { return }
            let api = GitHubAPI(token: token)
            do {
                for run in runs {
                    try await api.rerunFailedJobs(repository: activity.pullRequest.repository, runID: run)
                }
            } catch {
                NSSound.beep()
                return
            }
            showRerunning(activity)
            poll(after: .seconds(5))
        }
    }

    /// Merges the way GitHub's own button would. If GitHub won't, the
    /// pull request opens in the browser, which says why.
    func merge() {
        guard let activity, activity.phase == .ready, !isActing else { return }
        isActing = true
        Task {
            defer { isActing = false }
            guard let token = await currentToken() else { return }
            do {
                try await GitHubAPI(token: token).merge(activity.pullRequest)
            } catch {
                NSWorkspace.shared.open(activity.pullRequest.url)
            }
            if self.activity?.key == activity.key {
                dismiss()
            }
            poll(after: .seconds(2))
        }
    }

    private static func failedRuns(of pullRequest: GitHubPullRequest) -> [Int] {
        var runs: [Int] = []
        for check in pullRequest.checks where check.status == .failed {
            if let run = check.workflowRunID, !runs.contains(run) {
                runs.append(run)
            }
        }
        return runs
    }

    /// The failed checks back to running, until the next poll says how
    /// they're doing.
    private func showRerunning(_ activity: Activity) {
        guard let snapshot = latest else { return }
        let runs = Set(Self.failedRuns(of: activity.pullRequest))
        func rerunning(_ pullRequest: GitHubPullRequest) -> GitHubPullRequest {
            guard pullRequest.id == activity.id else { return pullRequest }
            var checks = pullRequest.checks
            for index in checks.indices where checks[index].status == .failed {
                if let run = checks[index].workflowRunID, runs.contains(run) {
                    checks[index].status = .running
                }
            }
            return pullRequest.with(checks: checks)
        }
        apply(GitHubSnapshot(
            login: snapshot.login,
            authored: snapshot.authored.map(rerunning),
            reviewRequested: snapshot.reviewRequested
        ))
    }

    /// Takes away a passed result after a moment, unless the notch is open
    /// or under the cursor; then it waits to be asked again.
    func leaveIfDue(after delay: Duration = .zero) {
        guard let key = duePassedKey, activity?.key == key else {
            duePassedKey = nil
            return
        }
        passedDismissal?.cancel()
        passedDismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.duePassedKey == key, self.activity?.key == key, !self.isInUse() else { return }
            self.duePassedKey = nil
            self.dismiss()
        }
    }

    private func scheduleLeaving(_ key: String) {
        passedDismissal?.cancel()
        duePassedKey = nil
        passedDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.passedDuration)
            guard !Task.isCancelled, let self else { return }
            self.duePassedKey = key
            self.leaveIfDue()
        }
    }
}

extension GitHubPullRequest {
    nonisolated func with(checks: [Check]) -> GitHubPullRequest {
        GitHubPullRequest(
            id: id, number: number, title: title, url: url, repository: repository, headSHA: headSHA,
            isDraft: isDraft, checks: checks, reviewDecision: reviewDecision, approvals: approvals,
            mergeable: mergeable, additions: additions, deletions: deletions, changedFiles: changedFiles,
            canMerge: canMerge, mergeMethod: mergeMethod
        )
    }
}

#if DEBUG
extension GitHubMonitor {
    /// An activity that stays as given, for SwiftUI previews.
    static func preview(_ activity: Activity) -> GitHubMonitor {
        let monitor = GitHubMonitor()
        monitor.activity = activity
        monitor.tokenProvider = { nil }
        return monitor
    }
}
#endif
