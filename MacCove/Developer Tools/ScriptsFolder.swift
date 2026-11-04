//
//  ScriptsFolder.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import Foundation

/// Where MacCove writes the scripts other apps run: ~/Library/Scripts,
/// the usual place for your own scripts, in a folder for each app.
///
/// No spaces anywhere in the paths. Xcode saves a script's location with
/// them percent-encoded and then can't find it, and Claude Code runs its
/// hook without a shell.
enum ScriptsFolder: String {
    case claudeCode = "ClaudeCode"
    case codex = "Codex"
    case terminal = "Terminal"
    case xcode = "Xcode"

    /// ~/Library/Scripts/MacCove, where every app's folder goes.
    static var root: URL {
        URL.libraryDirectory.appending(path: "Scripts/MacCove", directoryHint: .isDirectory)
    }

    var url: URL {
        Self.root.appending(path: rawValue, directoryHint: .isDirectory)
    }

    /// As it's shown to you: ~/Library/Scripts/MacCove/Xcode.
    var displayPath: String {
        "~/Library/Scripts/MacCove/\(rawValue)"
    }

    /// The same file where an earlier version wrote it, straight into
    /// ~/Library/Scripts/MacCove.
    static func unsortedURL(of fileName: String) -> URL {
        root.appending(path: fileName)
    }
}
