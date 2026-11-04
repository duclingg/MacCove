//
//  AgentSetupProtocol.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import Foundation

protocol AgentSetupProtocol {
    static func setup()
    static func remove()
    static func isInstalled() -> Bool
    static func hooksSetup() -> Bool
}

extension Notification.Name {
    /// Posted once Remove has taken MacCove's hooks out of an agent's
    /// settings, with the `AITool` as its object. `ClaudeCodeMonitor` then
    /// lets go of that agent's sessions.
    static let agentHooksRemoved = Notification.Name("MacCoveAgentHooksRemoved")
}
