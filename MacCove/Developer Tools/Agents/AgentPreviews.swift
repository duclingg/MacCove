//
//  AgentPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func session(_ phase: AgentMonitor.Phase, tasksDone: Int = 3, taskCount: Int = 5) -> AgentMonitor.Session {
    var session = AgentMonitor.Session(
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

private let approval = AgentMonitor.Approval(
    title: "Allow Bash command?",
    detail: ["$ git commit -m \"Hide island on external displays\""],
    alwaysAllow: ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "git commit:*"]], "behavior": "allow", "destination": "localSettings"]
)

private let question = AgentMonitor.question(from: [
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

private let plan = AgentMonitor.plan(from: [
    "plan": """
        # Hide the island on external displays

        1. Track which display has the menu bar.
        2. Tuck the island away on displays without a notch.
        3. Bring it back when the built-in display is main again.
        """,
    "planFilePath": "/Users/me/.claude/plans/hide-island.md",
])

private func compact(_ session: AgentMonitor.Session) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        AgentCompactView(agents: .preview(session), notchSize: notch)
    }
}

private func expanded(_ session: AgentMonitor.Session) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + AgentExpandedView.bodyHeight(for: session)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        AgentExpandedView(agents: .preview(session), notchHeight: notch.height)
    }
}

// MARK: Claude Code

#Preview("Claude Code working") {
    compact(session(.working))
}

#Preview("Claude Code working, no task list") {
    compact(session(.working, tasksDone: 0, taskCount: 0))
}

#Preview("Claude Code needs approval") {
    compact(session(.approval(approval)))
}

#Preview("Claude Code finished") {
    compact(session(.finished))
}

#Preview("Claude Code working, expanded") {
    expanded(session(.working))
}

#Preview("Claude Code working without a task list, expanded") {
    expanded(session(.working, tasksDone: 0, taskCount: 0))
}

#Preview("Claude Code needs approval, expanded") {
    expanded(session(.approval(approval)))
}

#Preview("Claude Code question, expanded") {
    expanded(session(.question(question)))
}

#Preview("Claude Code multiple choice, expanded") {
    var second = question
    second.index = 1
    second.selected = ["Built-in"]
    return expanded(session(.question(second)))
}

#Preview("Claude Code plan, expanded") {
    expanded(session(.plan(plan)))
}

#Preview("Claude Code finished, expanded") {
    expanded(session(.finished))
}

// MARK: Codex

private func codex(_ phase: AgentMonitor.Phase) -> AgentMonitor.Session {
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

private let codexApproval = AgentMonitor.Approval(
    title: AgentMonitor.approvalTitle(tool: "apply_patch", input: patch),
    detail: AgentMonitor.approvalDetail(tool: "apply_patch", input: patch),
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

// MARK: Cursor

/// Its own agent, in Cursor's app: no task list, and no Stop.
private func cursor(_ phase: AgentMonitor.Phase) -> AgentMonitor.Session {
    var result = session(phase, tasksDone: 0, taskCount: 0)
    result.agent = .cursor
    result.activity = "Running swift test"
    return result
}

#Preview("Cursor working") {
    compact(cursor(.working))
}

#Preview("Cursor working, expanded") {
    expanded(cursor(.working))
}

#Preview("Cursor finished, expanded") {
    expanded(cursor(.finished))
}
#endif
