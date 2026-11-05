//
//  CursorSetup.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

/// Adds MacCove's hooks to Cursor's user hooks file, ~/.cursor/hooks.json,
/// or takes them out. Cursor reloads the file when it changes.
///
/// The same arrangement as `ClaudeCodeSetup`: one script, `agent-hook.sh`,
/// posts each event's JSON to `AgentBridge` with `curl`. But nothing waits
/// for MacCove's answer. Cursor has no hook for only the commands it would
/// ask about, so answering from the notch would mean holding up every
/// command, even the ones it runs by itself. A hook that holds one up also
/// blocks it whenever it says nothing, as when MacCove isn't running.
/// So these hooks only report, and Cursor asks for approval itself.
enum CursorSetup: AgentSetupProtocol {
    static var scriptURL: URL {
        ScriptsFolder.cursor.url.appending(path: "agent-hook.sh")
    }

    /// How a handler's command starts when it's MacCove's, after the quote.
    private static let scriptSuffix = "/MacCove/Cursor/agent-hook.sh"

    /// Cursor's app, which also runs its agent.
    static let bundleIdentifier = "com.todesktop.230313mzl4w4u92"

    private static var cursorFolder: URL {
        URL.homeDirectory.appending(path: ".cursor", directoryHint: .isDirectory)
    }

    private static var hooksURL: URL {
        cursorFolder.appending(path: "hooks.json")
    }

    private static var backupURL: URL {
        cursorFolder.appending(path: "hooks.json.maccove-backup")
    }

    /// No sessionStart: a session appears with its first prompt, so a new
    /// chat that's still empty doesn't look busy. No preToolUse, which
    /// holds up the tool: postToolUse says what it did instead, and
    /// afterFileEdit which file it changed. A stop reports whether the
    /// turn finished or was stopped.
    private static let events = [
        "beforeSubmitPrompt",
        "postToolUse",
        "afterFileEdit",
        "stop",
        "sessionEnd",
    ]

    static var hookEvents: [String] {
        events
    }

    /// In seconds. Everything is reported, never waited on.
    private static let timeout = 5

    /// Writes the hook script and adds MacCove's hooks to Cursor's hooks
    /// file, or brings an earlier setup up to date. The file is backed up
    /// first, and other hooks stay as they are.
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
        }
    }

    /// Takes MacCove's hooks back out of Cursor's hooks file, leaving the
    /// rest as it was. The script stays, rewritten, so a run that's
    /// already under way doesn't hit a missing command.
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
            NotificationCenter.default.post(name: .agentHooksRemoved, object: AITool.cursor)
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Cursor itself

    /// Whether Cursor is on this Mac: the app, its `cursor-agent` command,
    /// or the ~/.cursor folder either of them makes on first run.
    static func isInstalled() -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil {
            return true
        }
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: cursorFolder.path(percentEncoded: false), isDirectory: &isFolder), isFolder.boolValue {
            return true
        }
        return fileManager.isExecutableFile(atPath: URL.homeDirectory.appending(path: ".local/bin/cursor-agent").path(percentEncoded: false))
    }

    // MARK: - The hooks file

    /// Whether Cursor's hooks file has MacCove's hook. Quietly `false`
    /// when it can't be read, since this is asked every time the settings
    /// pane draws; Set Up says what's wrong.
    static func hooksSetup() -> Bool {
        guard let file = try? readHooks() else { return false }
        let events = file["hooks"] as? [String: Any] ?? [:]
        return events.values.contains { handlers in
            (handlers as? [[String: Any]] ?? []).contains(where: isMacCoveHook)
        }
    }

    /// Cursor's hooks, or `nil` once it has said they aren't valid JSON,
    /// which MacCove won't overwrite.
    private static func readHooksOrSayWhy() -> [String: Any]? {
        do {
            return try readHooks()
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "MacCove Couldn’t Read Cursor’s Hooks"
            alert.informativeText = "~/.cursor/hooks.json isn’t valid JSON, so MacCove left it alone. \(error.localizedDescription)"
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
        try fileManager.createDirectory(at: cursorFolder, withIntermediateDirectories: true)
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

    /// Each event's handlers without MacCove's, dropping events left
    /// empty, and the file's `hooks` when nothing's left in it. Cursor
    /// lists handlers straight under each event, with no groups.
    private static func removing(from file: [String: Any]) -> [String: Any] {
        var file = file
        var events = file["hooks"] as? [String: Any] ?? [:]
        for (event, value) in events {
            guard let handlers = value as? [[String: Any]] else { continue }
            let kept = handlers.filter { !isMacCoveHook($0) }
            events[event] = kept.isEmpty ? nil : kept
        }
        file["hooks"] = events.isEmpty ? nil : events
        return file
    }

    /// Cursor runs the command through a shell, so the script's path is
    /// quoted, and the agent and event follow it. A new file gets the
    /// version Cursor wants.
    private static func adding(to file: [String: Any]) -> [String: Any] {
        var file = removing(from: file)
        if file["version"] == nil {
            file["version"] = 1
        }
        var hooks = file["hooks"] as? [String: Any] ?? [:]
        let script = scriptURL.path(percentEncoded: false)
        for event in events {
            var handlers = hooks[event] as? [[String: Any]] ?? []
            handlers.append([
                "command": "'\(script)' cursor \(event)",
                "timeout": timeout,
            ])
            hooks[event] = handlers
        }
        file["hooks"] = hooks
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
        # Run by Cursor's hooks, as set in ~/.cursor/hooks.json, so MacCove can
        # show the agent in the notch. Written by MacCove; changes are replaced
        # the next time you choose Set Up Cursor.
        #
        # $1 is the agent, $2 the hook event, and the event's JSON comes on stdin.
        # MacCove only listens: whatever happens, this tells Cursor to carry on,
        # which it does even when MacCove isn't running or the hook is gone.

        carry_on='{}'
        [ "$2" = beforeSubmitPrompt ] && carry_on='{"continue":true}'

        socket="$HOME/Library/Application Support/MacCove/agents.sock"
        if grep -qF '/MacCove/Cursor/agent-hook.sh' "$HOME/.cursor/hooks.json" 2>/dev/null && [ -S "$socket" ]; then
          # Cursor runs this through a shell, which may still be its parent.
          pid=$PPID
          case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
            *sh) pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') ;;
          esac
          tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')

          curl -sf -o /dev/null --max-time 2 --unix-socket "$socket" \
            -H 'Expect:' -H 'Content-Type: application/json' \
            -H "X-MacCove-App: ${__CFBundleIdentifier:-}" \
            -H "X-MacCove-TTY: $tty" \
            -H "X-MacCove-PID: $pid" \
            --data-binary @- "http://maccove/$1/$2"
        else
          cat > /dev/null
        fi

        printf '%s\n' "$carry_on"
        exit 0

        """#
}
