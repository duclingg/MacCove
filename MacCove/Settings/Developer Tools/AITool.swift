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
    
    var path: String {
        switch self {
        case .claude: "~/.claude/settings.json"
        case .codex: "~/.codex/hooks.json"
        case .cursor: "~/.cursor/config.json"
        }
    }
}
