import SwiftUI

extension Color {
    /// The design's orange for checks still running.
    static let githubChecks = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    /// The design's blue for a review request.
    static let githubReview = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    fileprivate static let onGreen = Color(red: 6 / 255, green: 33 / 255, blue: 15 / 255)
    fileprivate static let onWhite = Color(red: 20 / 255, green: 20 / 255, blue: 19 / 255)
    fileprivate static let codeText = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.86)
}

/// The design's pull request glyph: two commits joined, and a branch
/// coming back round to the first, drawn on a 24pt grid.
nonisolated private struct PullRequestShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for center in [CGPoint(x: 6, y: 6), CGPoint(x: 6, y: 18), CGPoint(x: 18, y: 18)] {
            path.addEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
        }
        path.move(to: CGPoint(x: 6, y: 8.5))
        path.addLine(to: CGPoint(x: 6, y: 15.5))
        path.move(to: CGPoint(x: 18, y: 15.5))
        path.addLine(to: CGPoint(x: 18, y: 9))
        path.addArc(center: CGPoint(x: 15, y: 9), radius: 3, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        path.addLine(to: CGPoint(x: 11, y: 6))
        path.move(to: CGPoint(x: 13, y: 3.5))
        path.addLine(to: CGPoint(x: 10.5, y: 6))
        path.addLine(to: CGPoint(x: 13, y: 8.5))
        let scale = min(rect.width, rect.height) / 24
        return path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.midX - 12 * scale, dy: rect.midY - 12 * scale)
    }
}

private struct PullRequestGlyph: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        PullRequestShape()
            .stroke(color, style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Blue for a review request, red for a failure or changes requested,
/// green once it's passed or approved, white while checks run or for a
/// comment.
private func activityTint(_ activity: GitHubMonitor.Activity?) -> Color {
    switch activity?.phase {
    case .review?: .githubReview
    case .failed?: .islandError
    case .ready?, .passed?: .islandSucceeded
    case .reviewed?: verdictColor(activity?.review?.verdict)
    case .running?, nil: .white
    }
}

private func verdictColor(_ verdict: GitHubPullRequest.Review.Verdict?) -> Color {
    switch verdict {
    case .approved?: .islandSucceeded
    case .changesRequested?: .islandError
    case .commented?, nil: .white
    }
}

/// "approved", "requested changes on", "commented on".
private func verdictPhrase(_ verdict: GitHubPullRequest.Review.Verdict) -> String {
    switch verdict {
    case .approved: "approved"
    case .changesRequested: "requested changes on"
    case .commented: "commented on"
    }
}

/// The reviewer's GitHub picture, with a badge for what they said: a
/// check, an exclamation mark for changes, or an ellipsis for comments.
private struct ReviewerAvatar: View {
    let review: GitHubPullRequest.Review
    let size: CGFloat

    var body: some View {
        AsyncImage(url: review.avatarURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: (size * 0.5).rounded()))
                    .foregroundStyle(.islandSecondary)
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            badge
                .offset(x: size * 0.1, y: size * 0.1)
        }
        .accessibilityHidden(true)
    }

    private var badge: some View {
        let badgeSize = (size * 0.44).rounded()
        let (symbol, background, foreground): (String, Color, Color) = switch review.verdict {
        case .approved: ("checkmark", Color.islandSucceeded, Color.onGreen)
        case .changesRequested: ("exclamationmark", Color.islandError, Color.white)
        case .commented: ("ellipsis", Color(white: 0.38), Color.white)
        }
        return Image(systemName: symbol)
            .font(.system(size: (badgeSize * 0.55).rounded(), weight: .heavy))
            .foregroundStyle(foreground)
            .frame(width: badgeSize, height: badgeSize)
            .background(Circle().fill(background))
            .background(Circle().fill(.black).padding(-max(1, (badgeSize * 0.12).rounded())))
    }
}

private func plural(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
}

private func checksClock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

/// "MacCove #6 · Hide the notch on external displays".
private func pullRequestLine(_ pullRequest: GitHubPullRequest) -> String {
    "\(pullRequest.repositoryName) #\(pullRequest.number) · \(pullRequest.title)"
}

/// How many checks have finished, out of all of them.
private func checksDone(_ pullRequest: GitHubPullRequest) -> (done: Int, total: Int) {
    (pullRequest.checks.filter { $0.status != .running }.count, pullRequest.checks.count)
}

private func checksFraction(_ pullRequest: GitHubPullRequest) -> Double {
    let (done, total) = checksDone(pullRequest)
    return total > 0 ? Double(done) / Double(total) : 0
}

/// Checks done in orange over a dim track.
private struct ChecksRing: View {
    let progress: Double
    /// Across the outside of the stroke.
    let diameter: CGFloat
    let lineWidth: CGFloat
    var color: Color = .githubChecks
    var trackOpacity = 0.2

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(trackOpacity), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
    }
}

/// The pull request glyph in the left wing. In the right: the checks done
/// as a ring while they run, a red cross for a failure, a green check once
/// they've passed, the reviewer's picture for a new review, or a blue dot
/// for a review request.
struct GitHubCompactView: View {
    let github: GitHubMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let activity = github.activity

        HStack(spacing: 0) {
            PullRequestGlyph(color: activity?.phase == .review ? .githubReview : .white, size: layout.artSize)
            Spacer(minLength: 0)
            if let activity {
                trailing(activity, size: layout.artSize)
            }
        }
        .padding(.horizontal, layout.sideInset)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.map(Self.accessibilityDescription) ?? "GitHub")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func trailing(_ activity: GitHubMonitor.Activity, size: CGFloat) -> some View {
        switch activity.phase {
        case .running:
            ChecksRing(progress: checksFraction(activity.pullRequest), diameter: 20, lineWidth: 3)
                .frame(width: size, height: size)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.islandError)
                .frame(width: size, height: size)
        case .ready, .passed:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.islandSucceeded)
                .frame(width: size, height: size)
        case .review:
            Circle()
                .fill(Color.githubReview)
                .frame(width: 8, height: 8)
                .frame(width: size, height: size)
        case .reviewed:
            if let review = activity.review {
                ReviewerAvatar(review: review, size: size)
            }
        }
    }

    private static func accessibilityDescription(_ activity: GitHubMonitor.Activity) -> String {
        let pullRequest = "\(activity.pullRequest.repositoryName) pull request \(activity.pullRequest.number)"
        switch activity.phase {
        case .running:
            let (done, total) = checksDone(activity.pullRequest)
            return "Checks running on \(pullRequest), \(done) of \(total) done"
        case .failed: return "Checks failed on \(pullRequest)"
        case .passed: return "Checks passed on \(pullRequest)"
        case .ready: return "\(pullRequest) is ready to merge"
        case .review: return "Review requested on \(pullRequest)"
        case .reviewed:
            guard let review = activity.review else { return "New review on \(pullRequest)" }
            return "\(review.author) \(verdictPhrase(review.verdict)) \(pullRequest)"
        }
    }
}

/// GitHub in a bubble beside another activity: the glyph inside the ring
/// while checks run, inside a red one after a failure, the reviewer's
/// picture for a new review, or tinted for how it stands.
struct GitHubMinimalView: View {
    let github: GitHubMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)
        let activity = github.activity
        let innerSize = (layout.ringDiameter * 0.55).rounded()

        Group {
            switch activity?.phase {
            case .running?:
                ZStack {
                    ChecksRing(
                        progress: activity.map { checksFraction($0.pullRequest) } ?? 0,
                        diameter: layout.ringDiameter,
                        lineWidth: layout.ringLineWidth,
                        trackOpacity: 0.18
                    )
                    PullRequestGlyph(color: .white, size: innerSize)
                }
            case .failed?:
                ZStack {
                    Circle()
                        .stroke(Color.islandError, lineWidth: layout.ringLineWidth)
                        .padding(layout.ringLineWidth / 2)
                        .frame(width: layout.ringDiameter, height: layout.ringDiameter)
                    PullRequestGlyph(color: .islandError, size: innerSize)
                }
            case .reviewed? where activity?.review != nil:
                if let review = activity?.review {
                    ReviewerAvatar(review: review, size: layout.artSize)
                }
            default:
                PullRequestGlyph(color: activityTint(activity), size: layout.artSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GitHub")
        .accessibilityAddTraits(.isButton)
    }
}

/// Opened up; the glyph opens the pull request. Checks running: a bar of
/// checks done and Open on GitHub. A new review: who, and what they wrote.
/// Otherwise a box saying what happened, and buttons for what to do about
/// it.
struct GitHubExpandedView: View {
    let github: GitHubMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let barGap: CGFloat = 10
    private static let barHeight: CGFloat = 6
    private static let footerGap: CGFloat = 6
    private static let footerHeight: CGFloat = 16
    private static let codeGap: CGFloat = 10
    private static let codePadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    private static let codeLineHeight: CGFloat = 18
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14
    /// Failed checks listed by name; past this, how many more.
    private static let maxFailedLines = 3
    private static let reviewFont = NSFont.systemFont(ofSize: 13)
    private static let reviewFontLineHeight = NSLayoutManager().defaultLineHeight(for: reviewFont)
    private static let reviewLineHeight = reviewFontLineHeight.rounded(.up) + 1
    /// A long review is cut off here; Open Review has the rest.
    private static let reviewLineLimit = 3

    static func bodyHeight(for activity: GitHubMonitor.Activity?) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        guard let activity else { return height }
        if activity.phase == .running {
            height += barGap + barHeight + footerGap + footerHeight
        } else if activity.phase == .reviewed, let review = activity.review {
            height += codeGap + codePadding.top + reviewBoxHeight(review) + codePadding.bottom
            height += chipsGap + chipHeight
        } else {
            let lines = codeLines(for: activity).count
            if lines > 0 {
                height += codeGap + codePadding.top + codeLineHeight * CGFloat(lines) + codePadding.bottom
            }
            height += chipsGap + chipHeight
        }
        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            if let activity = github.activity {
                header(activity)
                if activity.phase == .running {
                    progress(activity.pullRequest)
                } else if activity.phase == .reviewed, let review = activity.review {
                    reviewBox(review)
                        .padding(.top, Self.codeGap)
                    buttons(activity)
                        .padding(.top, Self.chipsGap)
                } else {
                    let lines = Self.codeLines(for: activity)
                    if !lines.isEmpty {
                        code(lines)
                            .padding(.top, Self.codeGap)
                    }
                    buttons(activity)
                        .padding(.top, Self.chipsGap)
                }
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private func header(_ activity: GitHubMonitor.Activity) -> some View {
        HStack(spacing: 12) {
            Button {
                github.openPullRequest()
            } label: {
                if let review = activity.review {
                    ReviewerAvatar(review: review, size: 44)
                        .contentShape(Circle())
                } else {
                    PullRequestGlyph(color: activityTint(activity), size: 26)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open on GitHub")

            VStack(alignment: .leading, spacing: 0) {
                Text(Self.title(activity))
                    .font(.system(size: 15, weight: .semibold))
                Text(pullRequestLine(activity.pullRequest))
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
                    .truncationMode(.tail)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if activity.phase == .running {
                Button {
                    github.openPullRequest()
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open on GitHub")
            }
        }
        .frame(height: Self.headerHeight)
    }

    /// The bar fills as checks finish. Under it, how many are done, and the
    /// check that has been running longest, with how long.
    private func progress(_ pullRequest: GitHubPullRequest) -> some View {
        let (done, total) = checksDone(pullRequest)
        let longest = pullRequest.checks
            .filter { $0.status == .running }
            .min { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }

        return VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.githubChecks)
                            .frame(width: proxy.size.width * checksFraction(pullRequest))
                            .animation(.easeInOut(duration: 0.4), value: done)
                    }
                }
                .frame(height: Self.barHeight)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text("\(done) of \(plural(total, "check")) done")
                Spacer(minLength: 0)
                if let longest {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(longest.startedAt.map { "\(longest.name) · \(checksClock(context.date.timeIntervalSince($0)))" } ?? longest.name)
                            .monospacedDigit()
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.islandSecondary)
            .lineLimit(1)
            .frame(height: Self.footerHeight)
            .padding(.top, Self.footerGap)
        }
        .padding(.top, Self.barGap)
    }

    private func code(_ lines: [CodeLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(line.text)
                    .foregroundStyle(line.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.codeLineHeight)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(Self.codePadding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    /// What the reviewer wrote, up to three lines, under the file it's on
    /// for a comment on the code.
    private func reviewBox(_ review: GitHubPullRequest.Review) -> some View {
        let lines = Self.reviewTextLines(review.text)

        return VStack(alignment: .leading, spacing: 0) {
            if let path = review.path {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.islandSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: Self.codeLineHeight)
            }
            Text(review.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.codeText)
                .lineLimit(Self.reviewLineLimit)
                .lineSpacing(max(0, Self.reviewLineHeight - Self.reviewFontLineHeight))
                .truncationMode(.tail)
                .frame(height: Self.reviewLineHeight * CGFloat(lines), alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Self.codePadding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    private static func reviewBoxHeight(_ review: GitHubPullRequest.Review) -> CGFloat {
        (review.path == nil ? 0 : codeLineHeight) + reviewLineHeight * CGFloat(reviewTextLines(review.text))
    }

    /// The box's height is worked out before anything is drawn, so the
    /// text is measured the way it will wrap, up to `reviewLineLimit`.
    private static func reviewTextLines(_ text: String) -> Int {
        let width = NotchViewModel.expandedWidth - NotchViewModel.expandedInset * 2 - codePadding.leading - codePadding.trailing
        let bounds = NSAttributedString(string: text, attributes: [.font: reviewFont]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lines = Int((bounds.height / reviewFontLineHeight).rounded())
        return min(max(lines, 1), reviewLineLimit)
    }

    @ViewBuilder
    private func buttons(_ activity: GitHubMonitor.Activity) -> some View {
        HStack(spacing: 8) {
            switch activity.phase {
            case .failed:
                // Only GitHub Actions can be re-run from here.
                if github.canRerun {
                    chip(github.isActing ? "Re-running…" : "Re-run Failed") { github.rerunFailed() }
                } else {
                    chip("Dismiss") { github.dismiss() }
                }
                chip("View Logs", background: .white, foreground: .onWhite) { github.viewLogs() }
            case .ready:
                chip("View") { github.openAndDismiss() }
                if activity.pullRequest.canMerge {
                    chip(github.isActing ? "Merging…" : "Merge", background: .islandSucceeded, foreground: .onGreen) {
                        github.merge()
                    }
                }
            case .passed:
                chip("Dismiss") { github.dismiss() }
                chip("View", background: .white, foreground: .onWhite) { github.openAndDismiss() }
            case .review:
                chip("Later") { github.dismiss() }
                chip("Open Pull Request", background: .githubReview, foreground: .white) { github.openAndDismiss() }
            case .reviewed:
                chip("Later") { github.dismiss() }
                if activity.review?.verdict == .approved {
                    chip("Open Review", background: .islandSucceeded, foreground: .onGreen) { github.openAndDismiss() }
                } else {
                    chip("Open Review", background: .white, foreground: .onWhite) { github.openAndDismiss() }
                }
            case .running:
                EmptyView()
            }
        }
        .disabled(github.isActing)
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

    // MARK: - Text

    private struct CodeLine: Identifiable {
        let id: Int
        let text: String
        let color: Color
    }

    private static func title(_ activity: GitHubMonitor.Activity) -> String {
        switch activity.phase {
        case .running: return "Checks running"
        case .failed:
            let failed = activity.pullRequest.checks.filter { $0.status == .failed }.count
            return "\(plural(failed, "check")) failed"
        case .passed: return "Checks passed"
        case .ready: return "Ready to merge"
        case .review: return "Review requested"
        case .reviewed:
            guard let review = activity.review else { return "New review" }
            return switch review.verdict {
            case .approved: "\(review.author) approved"
            case .changesRequested: "\(review.author) requested changes"
            case .commented: "\(review.author) commented"
            }
        }
    }

    /// Failed: each failed check in red, then how many passed. Passed: the
    /// count, and what it still waits on. Review: the size of the change.
    private static func codeLines(for activity: GitHubMonitor.Activity) -> [CodeLine] {
        let pullRequest = activity.pullRequest
        let checks = pullRequest.checks
        let passed = checks.filter { $0.status == .passed }.count
        var lines: [(String, Color)] = []
        switch activity.phase {
        case .running, .reviewed:
            break
        case .failed:
            let failed = checks.filter { $0.status == .failed }
            let shown = failed.count > maxFailedLines ? maxFailedLines - 1 : failed.count
            lines += failed.prefix(shown).map { ("✕  \($0.name)", Color.islandError) }
            if failed.count > shown {
                lines.append(("✕  \(failed.count - shown) more failed", Color.islandError))
            }
            if passed > 0 {
                lines.append(("✓  \(passed) other \(passed == 1 ? "check" : "checks") passed", Color.islandSucceeded))
            }
        case .ready:
            var text = "✓  \(plural(passed, "check")) passed"
            if pullRequest.approvals > 0 {
                text += "  ·  \(plural(pullRequest.approvals, "approval"))"
            }
            lines.append((text, Color.islandSucceeded))
        case .passed:
            lines.append(("✓  \(plural(passed, "check")) passed", Color.islandSucceeded))
            lines.append((waitingOn(pullRequest), Color.codeText))
        case .review:
            lines.append(("\(plural(pullRequest.changedFiles, "file")) changed", Color.codeText))
            lines.append(("+\(pullRequest.additions)  −\(pullRequest.deletions)", Color.islandSucceeded))
        }
        return lines.enumerated().map { CodeLine(id: $0.offset, text: $0.element.0, color: $0.element.1) }
    }

    private static func waitingOn(_ pullRequest: GitHubPullRequest) -> String {
        if pullRequest.isDraft { return "Still a draft" }
        if pullRequest.mergeable == "CONFLICTING" { return "Has merge conflicts" }
        if pullRequest.reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
        return "Waiting for a review"
    }
}
