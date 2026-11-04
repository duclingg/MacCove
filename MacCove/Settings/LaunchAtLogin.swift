//
//  LaunchAtLogin.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import Foundation
import OSLog
import ServiceManagement

@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false

    private static let log = Logger(subsystem: "com.justinhoang.MacCove", category: "LaunchAtLogin")
    private static let hasConfiguredKey = "LaunchAtLogin.hasConfigured"

    init() {
        if !UserDefaults.standard.bool(forKey: Self.hasConfiguredKey) {
            UserDefaults.standard.set(true, forKey: Self.hasConfiguredKey)
            setEnabled(true)
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.log.error("Couldn't \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// The user can also change this in System Settings › General › Login Items, so it's re-read whenever the menu opens.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
    }
}
