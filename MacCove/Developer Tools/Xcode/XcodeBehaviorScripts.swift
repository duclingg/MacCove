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
    private struct Script {
        let fileName: String
        /// The last part of the URL.
        let event: String
        /// As Xcode's Behaviors list them: the group, then the event.
        let group: String
        let behavior: String
    }

    /// No spaces anywhere in the path: Xcode saves the script's location
    /// with them percent-encoded, then can't find "Build%20Started.sh".
    private static let scripts = [
        Script(fileName: "xcode-build-started.sh", event: "started", group: "Build", behavior: "Starts"),
        Script(fileName: "xcode-build-succeeded.sh", event: "succeeded", group: "Build", behavior: "Succeeds"),
        Script(fileName: "xcode-build-failed.sh", event: "failed", group: "Build", behavior: "Fails"),
        Script(fileName: "xcode-test-started.sh", event: "test-started", group: "Testing", behavior: "Starts"),
        Script(fileName: "xcode-test-succeeded.sh", event: "test-succeeded", group: "Testing", behavior: "Succeeds"),
        Script(fileName: "xcode-test-failed.sh", event: "test-failed", group: "Testing", behavior: "Fails"),
        Script(fileName: "xcode-run-started.sh", event: "run-started", group: "Running", behavior: "Starts"),
        Script(fileName: "xcode-run-completed.sh", event: "run-completed", group: "Running", behavior: "Completes"),
        Script(fileName: "xcode-run-crashed.sh", event: "run-crashed", group: "Running", behavior: "Exits unexpectedly"),
    ]

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

    /// Writes the scripts (again, in case they've changed), then explains
    /// how to set them up, with a button that shows them in Finder.
    static func showSetup() {
        let urls: [URL]
        do {
            urls = try install()
            UserDefaults.standard.set(true, forKey: setUpKey)
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            return
        }

        // The folder is inside ~/Library, which Open panels hide, so its path
        // goes on the clipboard for Go to Folder.
        let path = directory.path(percentEncoded: false)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)

        let list = scripts
            .map { "\($0.group) › \($0.behavior): \($0.fileName)" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Show Xcode Builds, Tests and Runs in the Island"
        alert.informativeText = """
            In Xcode, choose Settings › Behaviors. For each of these, select it, turn on Run, then click \
            the menu beside it and choose Choose Script…. Press ⇧⌘G, paste, and pick the script:

            \(list)

            The scripts’ folder is copied, ready to paste:
            \(path)

            Set up only the ones you want. \(controlNote)
            """
        alert.addButton(withTitle: "Show Scripts in Finder")
        alert.addButton(withTitle: "Done")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Asked for once the setup's been explained, when Xcode is open.
    private static var controlNote: String {
        AutomationPermission.isRunning(XcodeScripting.bundleIdentifier)
            ? "MacCove then asks to control Xcode, for the scheme’s name and for Stop, Run and Test Again."
            : "The first one afterwards asks to let MacCove control Xcode, for the scheme’s name and for Stop, Run and Test Again."
    }

    /// After Set Up: asks to control Xcode, for the scheme's name and Stop,
    /// Run and Test Again, if it's open. If not, the first build afterwards
    /// asks.
    static func askToControlXcode() async {
        _ = await AutomationPermission.request(XcodeScripting.bundleIdentifier, openingHidden: false)
    }

    private static var scriptURLs: [URL] {
        scripts.map { directory.appending(path: $0.fileName) }
    }

    /// The scripts are written, so Xcode's Behaviors can run them. MacCove
    /// can't see which Behaviors you pointed at them.
    /// Set Up was clicked in MacCove and its scripts are there: what
    /// Settings and the welcome show as On.
    static var isSetUp: Bool {
        UserDefaults.standard.bool(forKey: setUpKey) && isInstalled()
    }

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
