//
//  XcodeBehaviorScripts.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit

/// The scripts Xcode's Behaviors run as a build or test run starts,
/// succeeds or fails, and as the app starts running, completes or exits
/// unexpectedly. Each opens a maccove://xcode URL for `XcodeBuildMonitor`,
/// with the workspace Xcode passes it. A behavior can only be pointed at a
/// script in Xcode's own settings, so MacCove writes them and says where
/// they go; nothing reaches the island until they're set up there.
enum XcodeBehaviorScripts {
    struct Script: Identifiable {
        var id: String { event }
        let fileName: String
        /// The last part of the URL.
        let event: String
        /// Xcode's own name for the event, in its preferences.
        let xcodeEvent: String
        /// As Xcode's Behaviors list them: the group, then the event.
        let group: String
        let behavior: String
    }

    /// No spaces anywhere in the path: Xcode saves the script's location
    /// with them percent-encoded, then can't find "Build%20Started.sh".
    static let scripts = [
        Script(fileName: "xcode-build-started.sh", event: "started", xcodeEvent: "BuildStart", group: "Build", behavior: "Starts"),
        Script(fileName: "xcode-build-succeeded.sh", event: "succeeded", xcodeEvent: "BuildSucceeds", group: "Build", behavior: "Succeeds"),
        Script(fileName: "xcode-build-failed.sh", event: "failed", xcodeEvent: "BuildFails", group: "Build", behavior: "Fails"),
        Script(fileName: "xcode-test-started.sh", event: "test-started", xcodeEvent: "TestingStart", group: "Testing", behavior: "Starts"),
        Script(fileName: "xcode-test-succeeded.sh", event: "test-succeeded", xcodeEvent: "TestingSucceeds", group: "Testing", behavior: "Succeeds"),
        Script(fileName: "xcode-test-failed.sh", event: "test-failed", xcodeEvent: "TestingFails", group: "Testing", behavior: "Fails"),
        Script(fileName: "xcode-run-started.sh", event: "run-started", xcodeEvent: "RunStart", group: "Running", behavior: "Starts"),
        Script(fileName: "xcode-run-completed.sh", event: "run-completed", xcodeEvent: "RunCompletes", group: "Running", behavior: "Completes"),
        Script(fileName: "xcode-run-crashed.sh", event: "run-crashed", xcodeEvent: "RunExitsUnexpectedly", group: "Running", behavior: "Exits unexpectedly"),
    ]

    /// Xcode's Behaviors groups, in the order it lists them.
    static let groups = ["Build", "Testing", "Running"]

    static func scripts(in group: String) -> [Script] {
        scripts.filter { $0.group == group }
    }

    /// Set Up was clicked in MacCove, so asking to control Xcode is
    /// expected. Scripts left behind in Xcode's Behaviors alone don't
    /// count. Read by `XcodeScripting`, off the main actor.
    nonisolated static let setUpKey = "XcodeBehaviorsSetUp"

    static var directory: URL {
        ScriptsFolder.xcode.url
    }

    /// Where the first version put them, under names with spaces that
    /// Xcode couldn't run.
    private static let oldDirectory = URL.applicationSupportDirectory.appending(path: "MacCove/Xcode", directoryHint: .isDirectory)
    private static let oldFileNames = ["Build Started.sh", "Build Succeeded.sh", "Build Failed.sh"]

    /// Set Up: writes the scripts (again, in case they've changed), puts
    /// their folder's path on the clipboard, and starts the guide in the
    /// notch. Nothing else moves: the steps stay in view above whatever's
    /// in front, Xcode's Settings included.
    static func guideInNotch() {
        guard prepare() else { return }
        XcodeSetupProgress.shared.guideInNotch()
    }

    /// Writes the scripts and copies their folder's path. Says why in an
    /// alert when they can't be written.
    @discardableResult
    static func prepare() -> Bool {
        do {
            try install()
            UserDefaults.standard.set(true, forKey: setUpKey)
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            return false
        }
        copyPath()
        return true
    }

    /// The folder is inside ~/Library, which Open panels hide, so its path
    /// goes on the clipboard for Go to Folder.
    static func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path(percentEncoded: false), forType: .string)
    }

    private static var scriptURLs: [URL] {
        scripts.map { directory.appending(path: $0.fileName) }
    }

    /// Set Up was clicked in MacCove and its scripts are there. Which of
    /// Xcode's Behaviors run them is up to `XcodeSetupProgress`.
    static var isSetUp: Bool {
        UserDefaults.standard.bool(forKey: setUpKey) && isInstalled()
    }

    /// The scripts are written, so Xcode's Behaviors can run them. MacCove
    /// can't see which Behaviors you pointed at them.
    static func isInstalled() -> Bool {
        scriptURLs.allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    static var scriptCount: Int {
        scripts.count
    }

    /// Selects the scripts in Finder.
    static func showScripts() {
        NSWorkspace.shared.activateFileViewerSelecting(scriptURLs)
    }

    @discardableResult
    private static func install() throws -> [URL] {
        removeOldScripts()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try scripts.map { script in
            let url = directory.appending(path: script.fileName)
            try contents(of: script).write(to: url, atomically: true, encoding: .utf8)
            // Xcode only runs scripts it can execute.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
            return url
        }
    }

    /// Only MacCove's own scripts, and their folder once it's empty. The
    /// ones written straight into ~/Library/Scripts/MacCove, before each
    /// app had a folder, go too, so Set Up's steps point Xcode at the new
    /// ones.
    private static func removeOldScripts() {
        let fileManager = FileManager.default
        for name in oldFileNames {
            try? fileManager.removeItem(at: oldDirectory.appending(path: name))
        }
        for script in scripts {
            try? fileManager.removeItem(at: ScriptsFolder.unsortedURL(of: script.fileName))
        }
        if (try? fileManager.contentsOfDirectory(atPath: oldDirectory.path(percentEncoded: false)))?.isEmpty == true {
            try? fileManager.removeItem(at: oldDirectory)
        }
    }

    /// Does nothing when MacCove isn't running, rather than launching it in
    /// the middle of a build. `open -g` leaves Xcode in front.
    private static func contents(of script: Script) -> String {
        """
        #!/bin/sh
        # Run by Xcode › Settings › Behaviors › \(script.group) › \(script.behavior), so MacCove
        # can show it in the island. Written by MacCove; changes are
        # replaced the next time you choose Set Up Xcode Builds.
        pgrep -xq MacCove || exit 0
        workspace=$(printf '%s' "$XcodeWorkspacePath" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/&/%26/g' -e 's/+/%2B/g' -e 's/?/%3F/g')
        open -g "maccove://xcode/\(script.event)?workspace=$workspace"

        """
    }
}
