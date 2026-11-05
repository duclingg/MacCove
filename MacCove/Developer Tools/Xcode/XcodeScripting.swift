//
//  XcodeScripting.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit
import ScriptingBridge

/// Talks to Xcode over Apple Events: which scheme and run destination a
/// workspace builds with.
///
/// Apple Events are synchronous round trips to Xcode, so they run on this
/// actor rather than the main thread. The first call after Set Up brings
/// up macOS's Automation prompt ("MacCove wants to control Xcode"); before
/// Set Up, Xcode's Behaviors running old scripts never do.
actor XcodeScripting {
    static let bundleIdentifier = "com.apple.dt.Xcode"

    nonisolated struct Workspace: Sendable {
        /// As Xcode reports it, for sending it commands.
        let path: String?
        let scheme: String?
        let destination: String?
    }

    private var app: SBApplication?

    /// The workspace at `path`, or Xcode's active one when there's no path
    /// to look for or nothing matches it.
    func workspace(at path: String?) -> Workspace? {
        guard mayAsk(), let document = document(at: path) else { return nil }
        let scheme = document.value(forKey: "activeScheme") as? SBObject
        let destination = document.value(forKey: "activeRunDestination") as? SBObject
        return Workspace(
            path: document.value(forKey: "path") as? String,
            scheme: scheme?.value(forKey: "name") as? String,
            destination: destination?.value(forKey: "name") as? String
        )
    }

    private func document(at path: String?) -> SBObject? {
        guard let app = runningApp() else { return nil }
        if let path,
           let documents = app.value(forKey: "workspaceDocuments") as? [SBObject],
           let match = documents.first(where: { document in
               (document.value(forKey: "path") as? String).map { XcodeBuildLogs.normalizedPath($0) } == path
           }) {
            return match
        }
        return app.value(forKey: "activeWorkspaceDocument") as? SBObject
    }

    /// Already allowed, or set up in MacCove, which says the first build
    /// afterwards asks.
    private func mayAsk() -> Bool {
        if UserDefaults.standard.bool(forKey: XcodeBehaviorScripts.setUpKey) {
            return true
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == OSStatus(noErr)
    }

    private func runningApp() -> SBApplication? {
        // Never launch Xcode just to ask it something.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty else {
            return nil
        }
        if app == nil {
            app = SBApplication(bundleIdentifier: Self.bundleIdentifier)
        }
        return app
    }
}

/// Stop, Run and Test from the island. Each returns as soon as Xcode has
/// the command, without waiting for it to finish, so they're quick enough
/// for NSAppleScript, which wants the main thread.
enum XcodeCommand: String {
    case stop
    case run
    case test

    /// Sent to the workspace at `documentPath` (as Xcode reported it), or
    /// the active one.
    func send(toDocumentAt documentPath: String?) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: XcodeScripting.bundleIdentifier).isEmpty else {
            return
        }
        var target = "active workspace document"
        if let documentPath {
            let quoted = documentPath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            target = "(first workspace document whose path is \"\(quoted)\")"
        }
        let source = """
            tell application id "\(XcodeScripting.bundleIdentifier)"
                \(rawValue) \(target)
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    /// Brings the workspace's window forward, or just Xcode.
    static func open(workspacePath: String?) {
        guard let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: XcodeScripting.bundleIdentifier) else {
            return
        }
        let workspaces = workspacePath.map { [URL(filePath: $0)] } ?? []
        NSWorkspace.shared.open(workspaces, withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
