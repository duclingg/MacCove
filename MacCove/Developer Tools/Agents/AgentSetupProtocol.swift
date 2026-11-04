//
//  AgentSetupProtocol.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

protocol AgentSetupProtocol {
    static func setup()
    static func remove()
    static func isInstalled() -> Bool
    static func hooksSetup() -> Bool
}
