//
//  ClaudeCodePreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func session(_ phase: ClaudeCodeMonitor.Phase, tasksDone: Int = 3, taskCount: Int = 5) -> ClaudeCodeMonitor.Session {
    var session = ClaudeCodeMonitor.Session(
        id: "preview",
        folder: "/Users/me/Developer/MacCove",
        task: "Hide island on external displays",
        startedAt: .now.addingTimeInterval(-252),
        phase: phase
    )
    session.activity = "Editing NotchWindowController.swift"
    session.tasksDone = tasksDone
    session.taskCount = taskCount
    session.toolUses = 23
    session.editedFiles = ["a", "b", "c", "d", "e"]
    if phase == .finished {
        session.finishedAt = .now.addingTimeInterval(156)
    }
    return session
}

private let approval = ClaudeCodeMonitor.Approval(
    title: "Allow Bash command?",
    detail: ["$ git commit -m \"Hide island on external displays\""],
    alwaysAllow: ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "git commit:*"]], "behavior": "allow", "destination": "localSettings"]
)

private let question = ClaudeCodeMonitor.question(from: [
    "questions": [
        [
            "header": "Notch width",
            "question": "How wide should the island be on displays without a notch?",
            "multiSelect": false,
            "options": [
                ["label": "Match the menu bar", "description": "As tall as the menu bar, 100pt across"],
                ["label": "Fixed 186pt", "description": "The same as a real notch"],
                ["label": "Fit the content", "description": "Only as wide as what it shows"],
            ],
        ],
        [
            "header": "Displays",
            "question": "Which displays should show it?",
            "multiSelect": true,
            "options": [
                ["label": "Built-in", "description": "The MacBook's own screen"],
                ["label": "External", "description": "Any display that's plugged in"],
            ],
        ],
    ],
])!

private let plan = ClaudeCodeMonitor.plan(from: [
    "plan": """
        # Hide the island on external displays

        1. Track which display has the menu bar.
        2. Tuck the island away on displays without a notch.
        3. Bring it back when the built-in display is main again.
        """,
    "planFilePath": "/Users/me/.claude/plans/hide-island.md",
])

private func compact(_ session: ClaudeCodeMonitor.Session) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        ClaudeCodeCompactView(claude: .preview(session), notchSize: notch)
    }
}

private func expanded(_ session: ClaudeCodeMonitor.Session) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + ClaudeCodeExpandedView.bodyHeight(for: session)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        ClaudeCodeExpandedView(claude: .preview(session), notchHeight: notch.height)
    }
}

#Preview("Working") {
    compact(session(.working))
}

#Preview("Working, no task list") {
    compact(session(.working, tasksDone: 0, taskCount: 0))
}

#Preview("Needs approval") {
    compact(session(.approval(approval)))
}

#Preview("Finished") {
    compact(session(.finished))
}

#Preview("Working, expanded") {
    expanded(session(.working))
}

#Preview("Working without a task list, expanded") {
    expanded(session(.working, tasksDone: 0, taskCount: 0))
}

#Preview("Needs approval, expanded") {
    expanded(session(.approval(approval)))
}

#Preview("Question, expanded") {
    expanded(session(.question(question)))
}

#Preview("Multiple choice, expanded") {
    var second = question
    second.index = 1
    second.selected = ["Built-in"]
    return expanded(session(.question(second)))
}

#Preview("Plan, expanded") {
    expanded(session(.plan(plan)))
}

#Preview("Finished, expanded") {
    expanded(session(.finished))
}

// MARK: Codex

private func codex(_ phase: ClaudeCodeMonitor.Phase) -> ClaudeCodeMonitor.Session {
    var result = session(phase, tasksDone: 2, taskCount: 4)
    result.agent = .codex
    result.activity = "Editing NotchWindowController.swift"
    return result
}

private let patch: [String: Any] = [
    "command": """
        *** Begin Patch
        *** Update File: MacCove/Notch/NotchWindowController.swift
        @@
        -        window.orderFront(nil)
        +        if screen.hasNotch { window.orderFront(nil) }
        *** End Patch
        """,
]

private let codexApproval = ClaudeCodeMonitor.Approval(
    title: ClaudeCodeMonitor.approvalTitle(tool: "apply_patch", input: patch),
    detail: ClaudeCodeMonitor.approvalDetail(tool: "apply_patch", input: patch),
    alwaysAllow: nil
)

#Preview("Codex working") {
    compact(codex(.working))
}

#Preview("Codex working, expanded") {
    expanded(codex(.working))
}

#Preview("Codex needs approval, expanded") {
    expanded(codex(.approval(codexApproval)))
}

#Preview("Codex finished, expanded") {
    expanded(codex(.finished))
}
#endif
