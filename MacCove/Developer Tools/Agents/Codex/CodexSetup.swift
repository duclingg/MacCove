//
//  CodexSetup.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

/// Adds MacCove's hooks to Codex's user hooks file, ~/.codex/hooks.json,
/// or takes them out.
///
/// The same arrangement as `ClaudeCodeSetup`: one script, `agent-hook.sh`,
/// posts each event's JSON to `AgentBridge` with `curl`, and only a
/// permission request waits for MacCove's answer. Codex has no `args` for
/// a hook, so the agent and event go on the end of its command.
///
/// Codex runs a hook only once you've trusted it, in its `/hooks`, so Set
/// Up says to do that.
enum CodexSetup: AgentSetupProtocol {
    static var scriptURL: URL {
        ScriptsFolder.codex.url.appending(path: "agent-hook.sh")
    }

    /// How a handler's command starts when it's MacCove's, after the quote.
    private static let scriptSuffix = "/MacCove/Codex/agent-hook.sh"

    private static var codexFolder: URL {
        URL.homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
    }

    private static var hooksURL: URL {
        codexFolder.appending(path: "hooks.json")
    }

    private static var backupURL: URL {
        codexFolder.appending(path: "hooks.json.maccove-backup")
    }

    private struct Hook {
        let event: String
        /// Reports nothing back, so Codex doesn't wait for it.
        var isBackground = false
        /// In seconds. Codex caps Interrupt and SessionEnd at 3.
        var timeout = 5
        /// Shown in Codex while it waits.
        var statusMessage: String?
    }

    /// No SessionStart: a session appears with its first prompt, so one
    /// sitting at an empty prompt doesn't look busy. Interrupt is Esc in
    /// the middle of a turn, which ends with no Stop.
    private static let hooks = [
        Hook(event: "UserPromptSubmit"),
        Hook(event: "PreToolUse", isBackground: true),
        Hook(event: "PostToolUse", isBackground: true),
        Hook(event: "PermissionRequest", timeout: 600, statusMessage: "Asking in MacCove"),
        Hook(event: "Stop"),
        Hook(event: "Interrupt", timeout: 3),
        Hook(event: "SessionEnd", timeout: 3),
    ]

    /// Writes the hook script and adds MacCove's hooks to Codex's hooks
    /// file, or brings an earlier setup up to date. The file is backed up
    /// first, and other hooks stay as they are. Then says how to trust
    /// them in Codex, which runs them from then on.
    static func setup() {
        guard let file = readHooksOrSayWhy() else { return }
        do {
            try writeScript()
            let updated = adding(to: file)
            if !NSDictionary(dictionary: updated).isEqual(to: file) {
                try save(updated)
            }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Trust MacCove’s Hooks in Codex"
        alert.informativeText = "Codex runs a hook only once you’ve trusted it. In Codex, type /hooks and trust MacCove’s. It asks again whenever MacCove updates them."
        alert.runModal()
    }

    /// Takes MacCove's hooks back out of Codex's hooks file, leaving the
    /// rest as it was. The script stays, so sessions that are already open
    /// don't run into a missing command; it's rewritten first, so one from
    /// an earlier Set Up also stops once the hooks are gone.
    static func remove() {
        guard let file = readHooksOrSayWhy() else { return }
        let updated = removing(from: file)
        guard !NSDictionary(dictionary: updated).isEqual(to: file) else { return }
        do {
            if FileManager.default.fileExists(atPath: scriptURL.path(percentEncoded: false)) {
                try writeScript()
            }
            try save(updated)
            // Nothing more comes from the sessions MacCove is showing, so
            // they'd stay as they are.
            NotificationCenter.default.post(name: .agentHooksRemoved, object: AITool.codex)
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Codex itself

    /// Where Codex's installers put the `codex` command: its own
    /// installer, Homebrew, and npm with Homebrew's Node or a user prefix.
    private static var commandURLs: [URL] {
        let home = URL.homeDirectory
        return [
            home.appending(path: ".local/bin/codex"),
            URL(filePath: "/opt/homebrew/bin/codex"),
            URL(filePath: "/usr/local/bin/codex"),
            home.appending(path: ".npm-global/bin/codex"),
            home.appending(path: ".bun/bin/codex"),
            home.appending(path: ".volta/bin/codex"),
        ]
    }

    /// Whether Codex is on this Mac: its `codex` command is in one of the
    /// usual places, or it has made ~/.codex, which it does on first run
    /// however it was installed (nvm's folders, for one, aren't checked).
    static func isInstalled() -> Bool {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: codexFolder.path(percentEncoded: false), isDirectory: &isFolder), isFolder.boolValue {
            return true
        }
        return commandURLs.contains { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    // MARK: - The hooks file

    /// Whether Codex's hooks file has MacCove's hook. Quietly `false` when
    /// it can't be read, since this is asked every time the settings pane
    /// draws; Set Up says what's wrong. Whether Codex trusts it isn't
    /// written anywhere MacCove can read.
    static func hooksSetup() -> Bool {
        guard let file = try? readHooks() else { return false }
        let events = file["hooks"] as? [String: Any] ?? [:]
        return events.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isMacCoveHook)
            }
        }
    }

    /// Codex's hooks, or `nil` once it has said they aren't valid JSON,
    /// which MacCove won't overwrite.
    private static func readHooksOrSayWhy() -> [String: Any]? {
        do {
            return try readHooks()
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "MacCove Couldn’t Read Codex’s Hooks"
            alert.informativeText = "~/.codex/hooks.json isn’t valid JSON, so MacCove left it alone. \(error.localizedDescription)"
            alert.runModal()
            return nil
        }
    }

    private static func readHooks() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL), !data.isEmpty else { return [:] }
        guard let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return file
    }

    /// Backs up what was there, then writes with sorted keys, so the file
    /// comes out the same each time.
    private static func save(_ file: [String: Any]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: codexFolder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: hooksURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: hooksURL, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: hooksURL, options: .atomic)
    }

    private static func isMacCoveHook(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(scriptSuffix + "' ") == true
    }

    /// Every event's groups without MacCove's handlers, dropping groups
    /// left empty, and the file's `hooks` when nothing's left in it.
    private static func removing(from file: [String: Any]) -> [String: Any] {
        var file = file
        var events = file["hooks"] as? [String: Any] ?? [:]
        for (event, value) in events {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let others = handlers.filter { !isMacCoveHook($0) }
                guard !others.isEmpty else { return nil }
                var group = group
                group["hooks"] = others
                return group
            }
            events[event] = kept.isEmpty ? nil : kept
        }
        file["hooks"] = events.isEmpty ? nil : events
        return file
    }

    /// Codex runs the command through a shell, so the script's path is
    /// quoted, and the agent and event follow it.
    private static func adding(to file: [String: Any]) -> [String: Any] {
        var file = removing(from: file)
        var events = file["hooks"] as? [String: Any] ?? [:]
        let script = scriptURL.path(percentEncoded: false)
        for hook in hooks {
            var handler: [String: Any] = [
                "type": "command",
                "command": "'\(script)' codex \(hook.event)",
                "timeout": hook.timeout,
            ]
            if hook.isBackground {
                handler["async"] = true
            }
            if let statusMessage = hook.statusMessage {
                handler["statusMessage"] = statusMessage
            }
            var groups = events[hook.event] as? [[String: Any]] ?? []
            groups.append(["hooks": [handler]])
            events[hook.event] = groups
        }
        file["hooks"] = events
        return file
    }

    // MARK: - The script

    private static func writeScript() throws {
        let url = scriptURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    private static let script = #"""
        #!/bin/sh
        # Run by Codex's hooks, as set in ~/.codex/hooks.json, so MacCove can
        # show the session in the notch. Written by MacCove; changes are
        # replaced the next time you choose Set Up Codex.
        #
        # $1 is the agent, $2 the hook event, and the event's JSON comes on stdin.
        # A permission request waits for MacCove's answer, which is printed for
        # Codex. When MacCove isn't running, nothing happens.
        #
        # After Remove Codex an open session may still run this. It does
        # nothing once the hook is no longer in the hooks file.

        grep -qF '/MacCove/Codex/agent-hook.sh' "$HOME/.codex/hooks.json" 2>/dev/null || exit 0

        socket="$HOME/Library/Application Support/MacCove/agents.sock"
        [ -S "$socket" ] || exit 0

        wait=5
        case "$2" in PermissionRequest) wait=600 ;; esac

        # Codex runs this through a shell, which may still be its parent.
        pid=$PPID
        case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
          *sh) pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') ;;
        esac
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')

        curl -sf --max-time "$wait" --unix-socket "$socket" \
          -H 'Expect:' -H 'Content-Type: application/json' \
          -H "X-MacCove-App: ${__CFBundleIdentifier:-}" \
          -H "X-MacCove-TTY: $tty" \
          -H "X-MacCove-PID: $pid" \
          --data-binary @- "http://maccove/$1/$2" || exit 0

        """#
}
