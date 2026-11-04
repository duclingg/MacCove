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
    @State private var hasAccessibility = AppMenuExtent.isAllowed
    @AppStorage(TerminalHook.thresholdKey) private var terminalThreshold = TerminalHook.defaultThreshold
    @AppStorage(ClipboardMonitor.enabledKey) private var isClipboardEnabled = false
    @State private var isClipboardRestricted = ClipboardMonitor.isAccessRestricted
    @AppStorage(NotchSettings.showInMenuBarKey) private var showsInMenuBar = true

    /// Xcode runs the app to draw SwiftUI previews, which shouldn't add a menu bar item each time.
    /// Previews in JIT mode set the playgrounds variable instead of the previews one.
    private static let isRunningForPreviews = ["XCODE_RUNNING_FOR_PREVIEWS", "XCODE_RUNNING_FOR_PLAYGROUNDS"]
        .contains { ProcessInfo.processInfo.environment[$0] == "1" }

    var body: some Scene {
        let _ = connectAppDelegate()

        MenuBarExtra("MacCove", systemImage: "capsule.tophalf.filled", isInserted: Binding(
            get: { showsInMenuBar && !Self.isRunningForPreviews },
            set: { showsInMenuBar = $0 }
        )) {
            Button("Settings", systemImage: "gear") {
                showSettings()
            }
            .onAppear {
                hasAccessibility = AppMenuExtent.isAllowed
                isClipboardRestricted = ClipboardMonitor.isAccessRestricted
                appDelegate.calendar.refreshPermissions()
            }
            Divider()
            Button("Quit MacCove") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        
        Window("Settings", id: Self.settingsWindowID) {
            SettingsView()
                .frame(width: 800, height: 600)
                .environment(appDelegate.github)
                .environment(appDelegate.nowPlaying)
                .environment(appDelegate.battery)
                .environment(appDelegate.signIn)
                .environment(appDelegate.clipboard)
                .environment(appDelegate.calendar)
                .environment(appDelegate.shelf)
                .environment(appDelegate.updates)
                .environment(appDelegate.notchCommands)
        }
        .windowResizability(.contentSize)
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
