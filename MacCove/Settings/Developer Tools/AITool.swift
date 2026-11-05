//
//  AITool.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import CoreGraphics
import SwiftUI

enum AITool: String, CaseIterable {
    case claude, codex, cursor
    
    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
    
    var icon: ToolIcon {
        switch self {
        case .claude: ToolIcon(.claudeCode)
        case .codex: ToolIcon(.codex)
        case .cursor: ToolIcon(.cursor)
        }
    }
    
    var setup: any AgentSetupProtocol.Type {
        switch self {
        case .claude: ClaudeCodeSetup.self
        case .codex: CodexSetup.self
        case .cursor: CursorSetup.self
        }
    }
    
    /// Whether Esc in its terminal stops a turn, as the notch's Stop does.
    /// Cursor's agent mostly runs in its own app, where it doesn't.
    var canStop: Bool {
        self != .cursor
    }

    /// After Set Up: what Stop and bringing the terminal forward need,
    /// asked for now rather than the first time they're used. Esc is sent
    /// as a key press, which needs Accessibility, and Terminal and iTerm
    /// are told which tab to bring forward.
    func askForPermissions() async {
        guard canStop else { return }
        if !CGPreflightPostEventAccess() {
            CGRequestPostEventAccess()
        }
        await TerminalWindow.askToControl()
    }

    var path: String {
        switch self {
        case .claude: "~/.claude/settings.json"
        case .codex: "~/.codex/hooks.json"
        case .cursor: "~/.cursor/hooks.json"
        }
    }
}
