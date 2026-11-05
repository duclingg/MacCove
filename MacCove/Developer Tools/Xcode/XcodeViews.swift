//
//  XcodeViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import SwiftUI

extension Color {
    /// The design's Xcode blue, for the ring, the bar and Open in Xcode.
    static let xcodeBuild = Color(red: 62 / 255, green: 155 / 255, blue: 1)
}

/// Xcode's own app icon, or a hammer if Xcode can't be found.
struct XcodeIcon: View {
    let size: CGFloat

    var body: some View {
        AppIcon(bundleIdentifier: XcodeScripting.bundleIdentifier, size: size, fallbackSystemName: "hammer.fill", fallbackTint: .xcodeBuild)
    }
}

/// How far a build or test run has got: the time so far against the last
/// successful one of the scheme, held short of full until Xcode says it's
/// done. `nil` without an earlier one to compare, and for runs.
private func buildProgress(_ build: XcodeBuildMonitor.Build, at date: Date) -> Double? {
    guard let startedAt = build.startedAt, let expected = build.expectedDuration, expected > 0 else { return nil }
    return min(0.96, date.timeIntervalSince(startedAt) / expected)
}

private func buildClock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

private func plural(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
}

/// The ring beside the notch: progress in Xcode blue over a dim track, or a
/// spinning arc for a scheme that hasn't been timed yet.
private struct BuildRing: View {
    let progress: Double?
    /// Across the outside of the stroke.
    let diameter: CGFloat
    let lineWidth: CGFloat
    var trackOpacity = 0.2

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        ZStack {
            Circle()
                .stroke(.white.opacity(trackOpacity), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.xcodeBuild, style: style)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
            } else {
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Color.xcodeBuild, style: style)
                        .rotationEffect(.degrees(spin(at: context.date, period: 1.2) * 360))
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
    }
}

/// 0 to 1 over each `period` seconds, for things that go round or back
/// and forth while there's no progress to show.
private func spin(at date: Date, period: TimeInterval) -> Double {
    date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
}

/// Xcode's icon in the left wing. In the right: the progress ring while
/// building or testing, a play glyph while the app runs, what went wrong
/// in red after a failure, or a green check.
struct XcodeCompactView: View {
    let xcode: XcodeBuildMonitor
    let notchSize: CGSize

    /// Each wing of a failed pill: room for "12 errors".
    static let failedWingWidth: CGFloat = 77

    /// The guide's pill has room for "4 of 9" until it's done.
    static func width(for xcode: XcodeBuildMonitor, notch: CGSize) -> CGFloat {
        if xcode.guide != nil {
            return xcode.guideGroup == nil ? NotchViewModel.compactWidth(notch: notch) : notch.width + failedWingWidth * 2
        }
        return width(for: xcode.build, notch: notch)
    }

    static func width(for build: XcodeBuildMonitor.Build?, notch: CGSize) -> CGFloat {
        if case .failed? = build?.phase {
            return notch.width + failedWingWidth * 2
        }
        return NotchViewModel.compactWidth(notch: notch)
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let build = xcode.build

        HStack(spacing: 0) {
            XcodeIcon(size: layout.artSize)
            Spacer(minLength: 0)
            if let guide = xcode.guide {
                guideTrailing(guide, size: layout.artSize)
            } else if let build {
                trailing(build, size: layout.artSize)
            }
        }
        .padding(.horizontal, layout.sideInset)
        .frame(width: Self.width(for: xcode, notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(xcode.guide != nil ? guideDescription : build.map { Self.accessibilityDescription($0) } ?? "Xcode")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func trailing(_ build: XcodeBuildMonitor.Build, size: CGFloat) -> some View {
        switch build.phase {
        case .inProgress where build.action == .run:
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.islandSucceeded)
                .frame(width: size, height: size)
        case .inProgress:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                BuildRing(progress: buildProgress(build, at: context.date), diameter: 20, lineWidth: 3)
            }
            .frame(width: size, height: size)
        case let .failed(_, errorCount, _):
            Text(Self.failureSummary(build.action, count: errorCount))
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.islandError)
                .lineLimit(1)
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.islandSucceeded)
                .frame(width: size, height: size)
        }
    }

    /// How many events have run, Allow in orange while macOS asks, or a
    /// check once there's nothing left.
    @ViewBuilder
    private func guideTrailing(_ guide: XcodeBuildMonitor.Guide, size: CGFloat) -> some View {
        if guide.isAsking {
            Text("Allow")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if xcode.guideGroup == nil {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.islandSucceeded)
                .frame(width: size, height: size)
        } else {
            Text("\(xcode.setup.count) of \(xcode.setup.total)")
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.xcodeBuild)
                .lineLimit(1)
        }
    }

    private var guideDescription: String {
        if xcode.guide?.isAsking == true { return "Connecting Xcode: allow MacCove to control Xcode" }
        if xcode.guideGroup == nil { return "Xcode is connected" }
        return "Connecting Xcode, \(xcode.setup.count) of \(xcode.setup.total) events working"
    }

    /// "3 errors", "2 failed", "Crashed", or "Failed" before anything has
    /// been counted.
    private static func failureSummary(_ action: XcodeBuildMonitor.Action, count: Int?) -> String {
        switch action {
        case .build: count.map { plural($0, "error") } ?? "Failed"
        case .test: count.map { "\($0) failed" } ?? "Failed"
        case .run: "Crashed"
        }
    }

    private static func accessibilityDescription(_ build: XcodeBuildMonitor.Build) -> String {
        let name = build.name
        switch (build.action, build.phase) {
        case (.build, .inProgress): return "Building \(name)"
        case (.test, .inProgress): return "Testing \(name)"
        case (.run, .inProgress): return "\(name) is running"
        case (.run, .failed): return "\(name) quit unexpectedly"
        case let (action, .failed(_, errorCount, _)):
            let noun = action == .build ? "build failed" : "tests failed"
            return "\(name) \(noun)" + (errorCount.map { ", \(failureSummary(action, count: $0))" } ?? "")
        case (.test, .succeeded): return "\(name) tests passed"
        case (_, .succeeded): return "\(name) build succeeded"
        }
    }
}

/// Xcode in a bubble beside another activity: its icon, inside the ring
/// while building or testing, and inside a red one after a failure.
struct XcodeMinimalView: View {
    let xcode: XcodeBuildMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)

        Group {
            if let build = xcode.build, build.phase == .inProgress, build.action != .run {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ZStack {
                        BuildRing(
                            progress: buildProgress(build, at: context.date),
                            diameter: layout.ringDiameter,
                            lineWidth: layout.ringLineWidth,
                            trackOpacity: 0.18
                        )
                        XcodeIcon(size: (layout.ringDiameter * 0.55).rounded())
                    }
                }
            } else if case .failed? = xcode.build?.phase {
                ZStack {
                    Circle()
                        .stroke(Color.islandError, lineWidth: layout.ringLineWidth)
                        .padding(layout.ringLineWidth / 2)
                        .frame(width: layout.ringDiameter, height: layout.ringDiameter)
                    XcodeIcon(size: (layout.ringDiameter * 0.55).rounded())
                }
            } else {
                XcodeIcon(size: layout.artSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Xcode")
        .accessibilityAddTraits(.isButton)
    }
}

/// Opened up. In progress: the scheme, run destination and configuration,
/// Open in Xcode and Stop, and for builds and tests a bar with the time
/// left. Failed: the first errors or failed tests, with Open in Xcode.
/// Succeeded: how long it took, with Run, or Test Again for tests.
struct XcodeExpandedView: View {
    let xcode: XcodeBuildMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let barGap: CGFloat = 10
    private static let barHeight: CGFloat = 6
    private static let footerGap: CGFloat = 6
    private static let footerHeight: CGFloat = 16
    private static let codeGap: CGFloat = 10
    private static let codePadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    private static let codeLineHeight: CGFloat = 18
    /// Each error wraps onto a second line at most.
    private static let codeLineLimit = 2
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    static func bodyHeight(for xcode: XcodeBuildMonitor) -> CGFloat {
        if xcode.guide != nil {
            return XcodeGuideView.bodyHeight(for: xcode)
        }
        return bodyHeight(for: xcode.build)
    }

    /// Grows with what's showing: the bar while building or testing, the
    /// errors and the buttons once it's done.
    static func bodyHeight(for build: XcodeBuildMonitor.Build?) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        switch build?.phase {
        case .inProgress?, nil:
            if build?.action != .run {
                height += barGap + barHeight + footerGap + footerHeight
            }
        case .failed?:
            let lines = codeLines(for: build).reduce(0) { $0 + $1.lineCount }
            if lines > 0 {
                height += codeGap + codePadding.top + codeLineHeight * CGFloat(lines) + codePadding.bottom
            }
            height += chipsGap + chipHeight
        case .succeeded?:
            height += chipsGap + chipHeight
        }
        return height
    }

    var body: some View {
        if xcode.guide != nil {
            XcodeGuideView(xcode: xcode, notchHeight: notchHeight)
        } else {
            buildBody
        }
    }

    private var buildBody: some View {
        let build = xcode.build

        return VStack(spacing: 0) {
            if let build {
                // Once a second for the time a run has been going.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    header(build, at: context.date)
                }
                if build.phase == .inProgress, build.action != .run {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        progress(build, at: context.date)
                    }
                }
                let lines = Self.codeLines(for: build)
                if !lines.isEmpty {
                    code(lines)
                        .padding(.top, Self.codeGap)
                }
                if build.phase != .inProgress {
                    buttons(build)
                        .padding(.top, Self.chipsGap)
                }
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    /// A failure has its title in red and a red badge on the icon.
    private func header(_ build: XcodeBuildMonitor.Build, at date: Date) -> some View {
        let isFailed = if case .failed = build.phase { true } else { false }
        return HStack(spacing: 12) {
            XcodeIcon(size: 44)
                .overlay(alignment: .bottomTrailing) {
                    if isFailed {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.islandError))
                            .background(Circle().fill(.black).padding(-2))
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.title(build))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isFailed ? Color.islandError : .white)
                Text(Self.subtitle(build, at: date))
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if build.phase == .inProgress {
                HStack(spacing: 8) {
                    circleButton("Open in Xcode", systemName: "arrow.up.forward.app", background: .white.opacity(0.14)) {
                        xcode.openInXcode()
                    }
                    circleButton(Self.stopLabel(build), systemName: "stop.fill", background: Color(red: 215 / 255, green: 0, blue: 21 / 255)) {
                        xcode.stop()
                    }
                }
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func progress(_ build: XcodeBuildMonitor.Build, at date: Date) -> some View {
        let fraction = buildProgress(build, at: date)
        let elapsed = build.startedAt.map { date.timeIntervalSince($0) } ?? 0

        return VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        if let fraction {
                            Capsule()
                                .fill(Color.xcodeBuild)
                                .frame(width: proxy.size.width * fraction)
                                .animation(.linear(duration: 1), value: fraction)
                        } else {
                            // Untimed: a short segment sweeps back and forth.
                            TimelineView(.animation) { context in
                                let segment = proxy.size.width * 0.3
                                let sweep = (1 - cos(spin(at: context.date, period: 2.4) * 2 * .pi)) / 2
                                Capsule()
                                    .fill(Color.xcodeBuild)
                                    .frame(width: segment)
                                    .offset(x: (proxy.size.width - segment) * sweep)
                            }
                        }
                    }
                }
                .frame(height: Self.barHeight)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            HStack {
                Text(Self.timeLeft(build, elapsed: elapsed))
                Spacer()
                Text(buildClock(elapsed))
                    .monospacedDigit()
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
        // Spaced so each line of a wrapped error takes `codeLineHeight`.
        let lineSpacing = Self.codeLineHeight - Self.codeFontLineHeight

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(line.text)
                    .foregroundStyle(line.isError ? Color.islandError : .islandSecondary)
                    .lineLimit(Self.codeLineLimit)
                    .lineSpacing(lineSpacing)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.codeLineHeight * CGFloat(line.lineCount))
            }
        }
        // The same SF Mono that `codeFont` measures.
        .font(.system(size: 12, design: .monospaced))
        .padding(Self.codePadding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    @ViewBuilder
    private func buttons(_ build: XcodeBuildMonitor.Build) -> some View {
        HStack(spacing: 8) {
            chip("Dismiss") { xcode.dismiss() }
            switch (build.action, build.phase) {
            case (_, .failed):
                chip("Open in Xcode", background: .xcodeBuild, foreground: Color(red: 4 / 255, green: 23 / 255, blue: 46 / 255)) {
                    xcode.openInXcode()
                    xcode.dismiss()
                }
            case (.test, _):
                chip("Test Again", background: .islandSucceeded, foreground: Color(red: 6 / 255, green: 33 / 255, blue: 15 / 255)) {
                    xcode.test()
                }
            default:
                chip("Run", background: .islandSucceeded, foreground: Color(red: 6 / 255, green: 33 / 255, blue: 15 / 255)) {
                    xcode.run()
                }
            }
        }
    }

    private func circleButton(_ label: String, systemName: String, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        let isError: Bool
        /// 1 or 2, as `text` wraps across the code box.
        let lineCount: Int
    }

    /// The first errors or failed tests, then how many more there are.
    private static func codeLines(for build: XcodeBuildMonitor.Build?) -> [CodeLine] {
        guard case let .failed(errors, errorCount, _)? = build?.phase, !errors.isEmpty else { return [] }
        var lines = errors.enumerated().map { index, error in
            let text = "\(error.location)  \(error.message)"
            return CodeLine(id: index, text: text, isError: true, lineCount: wrappedLineCount(text))
        }
        let more = (errorCount ?? errors.count) - errors.count
        if more > 0 {
            let text = "+\(more) more in Xcode"
            lines.append(CodeLine(id: lines.count, text: text, isError: false, lineCount: wrappedLineCount(text)))
        }
        return lines
    }

    /// The code box's height is worked out before anything is drawn, so
    /// the text is measured the way it will wrap, up to `codeLineLimit`.
    private static func wrappedLineCount(_ text: String) -> Int {
        let width = NotchViewModel.expandedWidth - NotchViewModel.expandedInset * 2 - codePadding.leading - codePadding.trailing
        let bounds = NSAttributedString(string: text, attributes: [.font: codeFont]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lines = Int((bounds.height / codeFontLineHeight).rounded())
        return min(max(lines, 1), codeLineLimit)
    }

    private static let codeFontLineHeight = NSLayoutManager().defaultLineHeight(for: codeFont)

    private static func title(_ build: XcodeBuildMonitor.Build) -> String {
        switch (build.action, build.phase) {
        case (.build, .inProgress): "Building \(build.name)"
        case (.test, .inProgress): "Testing \(build.name)"
        case (.run, .inProgress): "Running \(build.name)"
        case (.build, .failed): "Build failed"
        case (.test, .failed): "Tests failed"
        case (.run, .failed): "\(build.name) quit unexpectedly"
        case (.test, .succeeded): "Tests passed"
        case (_, .succeeded): "Build succeeded"
        }
    }

    /// "My Mac · Debug" while it goes on, with the time a run has been
    /// going; afterwards the scheme and configuration with the result,
    /// "MacCove · Debug · 3 errors, 1 warning".
    private static func subtitle(_ build: XcodeBuildMonitor.Build, at date: Date) -> String {
        var parts: [String] = []
        var result: [String] = []
        switch build.phase {
        case .inProgress:
            parts = [build.destination, build.configuration].compactMap { $0 }
            if build.action == .run, let startedAt = build.startedAt {
                parts.append(buildClock(date.timeIntervalSince(startedAt)))
            }
            if parts.isEmpty { parts = ["Xcode"] }
            return parts.joined(separator: " · ")
        case let .failed(_, errorCount, warningCount):
            switch build.action {
            case .build:
                if let errorCount { result.append(plural(errorCount, "error")) }
                if let warningCount, warningCount > 0 { result.append(plural(warningCount, "warning")) }
            case .test:
                if let errorCount {
                    result.append(build.testCount.map { "\(errorCount) of \($0) failed" } ?? "\(errorCount) failed")
                }
            case .run:
                if let duration = build.duration { result.append("after \(buildClock(duration))") }
            }
        case let .succeeded(warningCount):
            if build.action == .test, let testCount = build.testCount { result.append(plural(testCount, "test")) }
            if let duration = build.duration { result.append(buildClock(duration)) }
            if let warningCount, warningCount > 0 { result.append(plural(warningCount, "warning")) }
        }
        parts = [build.name, build.configuration].compactMap { $0 }
        if !result.isEmpty { parts.append(result.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private static func stopLabel(_ build: XcodeBuildMonitor.Build) -> String {
        switch build.action {
        case .build: "Stop build"
        case .test: "Stop tests"
        case .run: "Stop \(build.name)"
        }
    }

    /// "About 31 s left · last build took 1:12", never quite reaching zero
    /// since the last one is only a guess.
    private static func timeLeft(_ build: XcodeBuildMonitor.Build, elapsed: TimeInterval) -> String {
        let noun = build.action == .test ? "test run" : "build"
        guard let expected = build.expectedDuration else { return "No earlier \(noun) to compare" }
        let left = max(5, Int((expected - elapsed).rounded()))
        return "About \(left) s left · last \(noun) took \(buildClock(expected))"
    }
}
