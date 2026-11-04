//
//  XcodePreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func inProgress(_ action: XcodeBuildMonitor.Action, expected: TimeInterval?) -> XcodeBuildMonitor.Build {
    XcodeBuildMonitor.Build(
        action: action,
        workspacePath: "/Users/me/Developer/MacCove/MacCove.xcodeproj",
        scheme: "MacCove",
        destination: "My Mac",
        configuration: "Debug",
        startedAt: .now.addingTimeInterval(-41),
        expectedDuration: expected,
        phase: .inProgress
    )
}

private let buildFailed = XcodeBuildMonitor.Build(
    action: .build,
    scheme: "MacCove",
    configuration: "Debug",
    phase: .failed(
        errors: [
            XcodeBuildIssue(location: "IslandView.swift:48", message: "Cannot find 'hasNotch' in scope"),
            XcodeBuildIssue(
                location: "NotchWindowController.swift:112",
                message: "Missing return in instance method expected to return 'CGRect'; did you mean to return the island's frame?"
            ),
        ],
        errorCount: 3,
        warningCount: 1
    )
)

private let buildSucceeded = XcodeBuildMonitor.Build(
    action: .build,
    scheme: "MacCove",
    configuration: "Debug",
    startedAt: .now.addingTimeInterval(-72),
    finishedAt: .now,
    phase: .succeeded(warningCount: 2)
)

private let testsFailed = XcodeBuildMonitor.Build(
    action: .test,
    scheme: "MacCove",
    configuration: "Debug",
    testCount: 60,
    phase: .failed(
        errors: [
            XcodeBuildIssue(location: "testCompactWidth()", message: "XCTAssertEqual failed: (\"274.0\") is not equal to (\"298.0\")"),
            XcodeBuildIssue(location: "testBubbleGap()", message: "Expectation failed: bubble.frame.minX > island.frame.maxX + 8"),
        ],
        errorCount: 3,
        warningCount: nil
    )
)

private let testsPassed = XcodeBuildMonitor.Build(
    action: .test,
    scheme: "MacCove",
    configuration: "Debug",
    startedAt: .now.addingTimeInterval(-42),
    finishedAt: .now,
    testCount: 60,
    phase: .succeeded(warningCount: nil)
)

private let runCrashed = XcodeBuildMonitor.Build(
    action: .run,
    scheme: "MacCove",
    configuration: "Debug",
    startedAt: .now.addingTimeInterval(-151),
    finishedAt: .now,
    phase: .failed(errors: [], errorCount: nil, warningCount: nil)
)

private func compact(_ build: XcodeBuildMonitor.Build) -> some View {
    IslandPreview(
        size: CGSize(width: XcodeCompactView.width(for: build, notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        XcodeCompactView(xcode: .preview(build), notchSize: notch)
    }
}

private func expanded(_ build: XcodeBuildMonitor.Build) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + XcodeExpandedView.bodyHeight(for: build)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        XcodeExpandedView(xcode: .preview(build), notchHeight: notch.height)
    }
}

// MARK: - Builds

#Preview("Building") {
    compact(inProgress(.build, expected: 72))
}

#Preview("Building, first time") {
    compact(inProgress(.build, expected: nil))
}

#Preview("Build failed") {
    compact(buildFailed)
}

#Preview("Build succeeded") {
    compact(buildSucceeded)
}

#Preview("Building, expanded") {
    expanded(inProgress(.build, expected: 72))
}

#Preview("Building, first time, expanded") {
    expanded(inProgress(.build, expected: nil))
}

#Preview("Build failed, expanded") {
    expanded(buildFailed)
}

#Preview("Build succeeded, expanded") {
    expanded(buildSucceeded)
}

// MARK: - Tests

#Preview("Testing") {
    compact(inProgress(.test, expected: 60))
}

#Preview("Tests failed") {
    compact(testsFailed)
}

#Preview("Testing, expanded") {
    expanded(inProgress(.test, expected: 60))
}

#Preview("Tests failed, expanded") {
    expanded(testsFailed)
}

#Preview("Tests passed, expanded") {
    expanded(testsPassed)
}

// MARK: - Running

#Preview("Running") {
    compact(inProgress(.run, expected: nil))
}

#Preview("Crashed") {
    compact(runCrashed)
}

#Preview("Running, expanded") {
    expanded(inProgress(.run, expected: nil))
}

#Preview("Crashed, expanded") {
    expanded(runCrashed)
}
#endif
