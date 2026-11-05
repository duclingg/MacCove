//
//  ResetEverything.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import ServiceManagement

/// Reset All Settings: everything MacCove has set up on this Mac comes out,
/// so it's as it was before MacCove first opened, and a new MacCove opens
/// to the welcome.
///
/// What goes: the hooks in Claude Code's, Codex's and Cursor's settings,
/// the lines in ~/.zshrc, Xcode's Behaviors that run MacCove's scripts,
/// the scripts themselves, the GitHub token, the Low Power Mode helper and
/// opening at login, the files on the shelf, every setting, and the
/// permissions macOS has given MacCove. What stays: the backups MacCove
/// made of other apps' settings before changing them, which are yours.
enum ResetEverything {
    static func resetAndRelaunch() {
        removeAgentHooks()
        TerminalHook.remove()
        XcodeSetupProgress.removeFromXcode()
        try? FileManager.default.removeItem(at: ScriptsFolder.root)
        GitHubKeychain.token = nil
        unregisterBackgroundItems()
        removeFiles()
        clearSettings()
        resetPermissions()
        relaunch()
    }

    /// Only from agents that have them, so a settings file MacCove never
    /// touched isn't read or rewritten.
    private static func removeAgentHooks() {
        for tool in AITool.allCases where tool.setup.hooksSetup() {
            tool.setup.remove()
        }
    }

    private static func unregisterBackgroundItems() {
        try? SMAppService.daemon(plistName: LowPowerModeHelper.plistName).unregister()
        try? SMAppService.mainApp.unregister()
    }

    /// ~/Library/Application Support/MacCove: the shelf's files and the
    /// agents' socket, which the new MacCove makes again.
    private static func removeFiles() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: URL.applicationSupportDirectory.appending(path: "MacCove", directoryHint: .isDirectory))
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            try? fileManager.removeItem(at: URL.cachesDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory))
        }
    }

    private static func clearSettings() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }

    /// Calendar, Reminders, the camera, Accessibility, Automation and the
    /// rest: macOS asks again the next time each is set up.
    private static func resetPermissions() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Opens a new MacCove once this one has quit, so the two never both
    /// hold the agents' socket and every monitor starts from its defaults.
    private static func relaunch() {
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path(percentEncoded: false)]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
