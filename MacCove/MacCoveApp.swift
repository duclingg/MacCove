//
//  MacCoveApp.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import SwiftUI

@main
struct MacCoveApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(TerminalHook.thresholdKey) private var terminalThreshold = TerminalHook.defaultThreshold
    @AppStorage(ClipboardMonitor.enabledKey) private var isClipboardEnabled = false

    var body: some Scene {
        let _ = connectAppDelegate()

        // The menu bar item is AppKit's, made by AppDelegate, so it can be
        // hidden the way System Settings hides it.
        Window("Settings", id: Self.settingsWindowID) {
            SettingsView()
                .frame(width: 800, height: 600)
                .environment(appDelegate.github)
                .environment(appDelegate.downloads)
                .environment(appDelegate.nowPlaying)
                .environment(appDelegate.battery)
                .environment(appDelegate.signIn)
                .environment(appDelegate.clipboard)
                .environment(appDelegate.calendar)
                .environment(appDelegate.reminders)
                .environment(appDelegate.deviceBatteries)
                .environment(appDelegate.mirror)
                .environment(appDelegate.shelf)
                .environment(appDelegate.updates)
                .environment(appDelegate.notchCommands)
                .environment(appDelegate.menuBarItem)
        }
        .windowResizability(.contentSize)
        // Opens from the menu bar item or by opening MacCove again, not at
        // launch.
        .defaultLaunchBehavior(.suppressed)
    }

    private static let settingsWindowID = "settings-window"

    /// AppDelegate has no SwiftUI environment to open windows with, so opening MacCove again,
    /// the way back to Settings once the menu bar item is hidden, comes through here.
    private func connectAppDelegate() {
        appDelegate.showSettings = showSettings
    }
    
    private func showSettings() {
        openWindow(id: Self.settingsWindowID)
        Task { @MainActor in
            NSApp.activate()
            let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.settingsWindowID) == true }
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }
}
