#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func check(
    _ name: String,
    _ status: GitHubPullRequest.Check.Status,
    startedSecondsAgo: TimeInterval = 151
) -> GitHubPullRequest.Check {
    GitHubPullRequest.Check(
        id: name,
        name: name,
        status: status,
        startedAt: .now.addingTimeInterval(-startedSecondsAgo),
        url: nil,
        workflowRunID: 1
    )
}

private func pullRequest(
    number: Int = 6,
    title: String = "Hide the notch on external displays",
    checks: [GitHubPullRequest.Check],
    approvals: Int = 1,
    reviewDecision: String? = "APPROVED"
) -> GitHubPullRequest {
    GitHubPullRequest(
        id: "PR_\(number)",
        number: number,
        title: title,
        url: URL(string: "https://github.com/duclingg/MacCove/pull/\(number)")!,
        repository: "duclingg/MacCove",
        headSHA: "abc123",
        isDraft: false,
        checks: checks,
        reviewDecision: reviewDecision,
        approvals: approvals,
        mergeable: "MERGEABLE",
        additions: 214,
        deletions: 38,
        changedFiles: 6,
        canMerge: true,
        mergeMethod: "SQUASH"
    )
}

private let running = GitHubMonitor.Activity(
    pullRequest: pullRequest(checks: [
        check("build-and-test", .running),
        check("swiftlint", .running, startedSecondsAgo: 40),
        check("docs", .passed), check("unit-tests", .passed), check("codeql", .passed), check("danger", .passed),
    ]),
    phase: .running
)

private let failed = GitHubMonitor.Activity(
    pullRequest: pullRequest(checks: [
        check("build-and-test (macos-15)", .failed), check("swiftlint", .failed),
        check("docs", .passed), check("unit-tests", .passed), check("codeql", .passed), check("danger", .passed),
    ]),
    phase: .failed
)

private let ready = GitHubMonitor.Activity(
    pullRequest: pullRequest(checks: (1 ... 6).map { check("check-\($0)", .passed) }),
    phase: .ready
)

private let review = GitHubMonitor.Activity(
    pullRequest: pullRequest(number: 7, title: "Add Xcode build activity", checks: []),
    phase: .review
)

private func reviewed(_ verdict: GitHubPullRequest.Review.Verdict, text: String, path: String? = nil) -> GitHubMonitor.Activity {
    GitHubMonitor.Activity(
        pullRequest: pullRequest(checks: [check("build-and-test", .passed)]),
        phase: .reviewed,
        review: GitHubPullRequest.Review(
            id: "review",
            verdict: verdict,
            author: "octocat",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/583231?s=96"),
            text: text,
            path: path,
            url: nil,
            submittedAt: .now
        )
    )
}

private let changesRequested = reviewed(
    .changesRequested,
    text: "The notch still flashes on the external display when the menu bar auto-hides. Can we wait for the screen parameters to settle before measuring?"
)

private let commented = reviewed(
    .commented,
    text: "Should this use the cached frame instead?",
    path: "MacCove/Notch/NotchWindowController.swift"
)

private func compact(_ activity: GitHubMonitor.Activity) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        GitHubCompactView(github: .preview(activity), notchSize: notch)
    }
}

private func expanded(_ activity: GitHubMonitor.Activity) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + GitHubExpandedView.bodyHeight(for: activity)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        GitHubExpandedView(github: .preview(activity), notchHeight: notch.height)
    }
}

#Preview("Checks running") {
    compact(running)
}

#Preview("Checks running, expanded") {
    expanded(running)
}

#Preview("Checks failed") {
    compact(failed)
}

#Preview("Checks failed, expanded") {
    expanded(failed)
}

#Preview("Ready to merge") {
    compact(ready)
}

#Preview("Ready to merge, expanded") {
    expanded(ready)
}

#Preview("Review requested") {
    compact(review)
}

#Preview("Review requested, expanded") {
    expanded(review)
}

#Preview("Changes requested") {
    compact(changesRequested)
}

#Preview("Changes requested, expanded") {
    expanded(changesRequested)
}

#Preview("Approved, expanded") {
    expanded(reviewed(.approved, text: "Looks great, thanks!"))
}

#Preview("Comment on the code, expanded") {
    expanded(commented)
}
#endif
