//
//  AITool.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

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
    
    @ViewBuilder var icon: some View {
        switch self {
        case .claude: ClaudeCodeIcon(size: 25)
        case .codex: Image(systemName: "exclamationmark.triangle")
        case .cursor: Image(systemName: "exclamationmark.triangle")
        }
    }
    
    var setup: any AgentSetupProtocol.Type {
        switch self {
        case .claude: ClaudeCodeSetup.self
        case .codex: CodexSetup.self
        case .cursor: CursorSetup.self
        }
    }
    
    var path: String {
        switch self {
        case .claude: "~/.claude/settings.json"
        case .codex: "~/.codex/hooks.json"
        case .cursor: "~/.cursor/config.json"
        }
    }
}
