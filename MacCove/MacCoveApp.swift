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
        .defaultLaunchBehavior(.suppressed)
    }

    private static let settingsWindowID = "settings-window"

    private func connectAppDelegate() {
        appDelegate.showSettings = showSettings
    }
    
    private func showSettings() {
        openWindow(id: Self.settingsWindowID)
        Task { @MainActor in
            for _ in 0..<20 {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(Self.settingsWindowID) == true }) {
                    Self.bringForward(window)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private static func bringForward(_ window: NSWindow) {
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.unhide(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
