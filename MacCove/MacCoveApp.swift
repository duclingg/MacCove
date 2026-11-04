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
    @AppStorage(GitHubSetup.sourceKey) private var githubSource = ""
    /// Copies don't show, or ask every time, once macOS restricts reading
    /// the clipboard.
    @State private var isClipboardRestricted = ClipboardMonitor.isAccessRestricted

    /// Xcode runs the app to draw SwiftUI previews, which shouldn't add a
    /// menu bar item each time. Previews in JIT mode set the playgrounds
    /// variable instead of the previews one.
    private static let isRunningForPreviews = ["XCODE_RUNNING_FOR_PREVIEWS", "XCODE_RUNNING_FOR_PLAYGROUNDS"]
        .contains { ProcessInfo.processInfo.environment[$0] == "1" }

    var body: some Scene {
        MenuBarExtra("MacCove", systemImage: "capsule.tophalf.filled", isInserted: .constant(!Self.isRunningForPreviews)) {
            Button("Settings", systemImage: "gear") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings-window")
            }
            .onAppear {
                hasAccessibility = AppMenuExtent.isAllowed
                isClipboardRestricted = ClipboardMonitor.isAccessRestricted
                appDelegate.calendar.refreshPermissions()
            }
            
            Button("Set Up Xcode Builds…") {
                XcodeBehaviorScripts.showSetup()
            }
            Button("Set Up Terminal Commands…") {
                TerminalHook.showSetup()
            }
            Button(githubSource.isEmpty ? "Connect GitHub…" : "GitHub Pull Requests…") {
                appDelegate.showGitHubSetup()
            }
            if !hasAccessibility {
                Button("Allow Accessibility Access…") {
                    AppMenuExtent.openSettings()
                }
            }
            Picker("Show Terminal Commands After", selection: Binding(
                get: { terminalThreshold },
                set: { seconds in
                    terminalThreshold = seconds
                    TerminalHook.setThreshold(seconds)
                }
            )) {
                ForEach(TerminalHook.thresholdOptions, id: \.self) { seconds in
                    Text(seconds < 60 ? "\(seconds) Seconds" : "\(seconds / 60) Minute").tag(seconds)
                }
            }
            Divider()
            // Off until asked for: copies are kept 24 hours, on this Mac
            // only, and passwords never.
            Toggle("Clipboard History", isOn: Binding(
                get: { isClipboardEnabled },
                set: { enabled in
                    isClipboardEnabled = enabled
                    appDelegate.setClipboardEnabled(enabled)
                }
            ))
            if isClipboardEnabled {
                if isClipboardRestricted {
                    Button("Allow Clipboard Access…") {
                        ClipboardMonitor.openAccessSettings()
                    }
                }
                Button("Show Clipboard History") {
                    appDelegate.showClipboardHistory()
                }
            }
            Divider()
            CalendarMenu(calendar: appDelegate.calendar) {
                appDelegate.showTodayEvents()
            }
            Divider()
            Button("Quit MacCove") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        
        Window("Settings", id: "settings-window") {
            SettingsView()
                .frame(width: 800, height: 600)
        }
        .windowResizability(.contentSize)
    }
}
