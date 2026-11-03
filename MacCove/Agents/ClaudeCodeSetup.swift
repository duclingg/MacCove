import AppKit

/// Adds MacCove's hook to Claude Code's user settings, or takes it out.
///
/// One script, `agent-hook.sh`, posts each event's JSON to `AgentBridge`
/// with `curl`. Claude Code runs it directly with the agent and event as
/// arguments, so its parent process is Claude Code itself, whose terminal
/// it reports. Most events run in the background and never hold Claude up;
/// a permission request, a question or a finished plan waits for MacCove's
/// answer.
enum ClaudeCodeSetup {
    /// Beside the Xcode scripts and the terminal hook. No spaces, so Claude
    /// Code can run it without a shell.
    static var scriptURL: URL {
        URL.libraryDirectory.appending(path: "Scripts/MacCove/agent-hook.sh")
    }

    private static var settingsURL: URL {
        URL.homeDirectory.appending(path: ".claude/settings.json")
    }

    private static var backupURL: URL {
        URL.homeDirectory.appending(path: ".claude/settings.json.maccove-backup")
    }

    private struct Hook {
        let event: String
        /// What the script passes on to MacCove, when it isn't the event.
        var name: String?
        /// The tools it runs for, when not all of them.
        var matcher: String?
        /// Reports nothing back, so Claude doesn't wait for it.
        var isBackground = false
        var timeout = 5
    }

    /// No SessionStart: a session appears with its first prompt, so one
    /// sitting at an empty prompt doesn't look busy. Questions and plans
    /// get a PreToolUse of their own that waits for an answer, so no other
    /// tool waits on MacCove.
    private static let hooks = [
        Hook(event: "UserPromptSubmit"),
        Hook(event: "PreToolUse", isBackground: true),
        Hook(event: "PreToolUse", name: "UserInput", matcher: "AskUserQuestion|ExitPlanMode", timeout: 600),
        Hook(event: "PostToolUse", isBackground: true),
        Hook(event: "TaskCreated", isBackground: true),
        Hook(event: "TaskCompleted", isBackground: true),
        Hook(event: "PermissionRequest", timeout: 600),
        Hook(event: "Notification", isBackground: true),
        Hook(event: "Stop"),
        Hook(event: "SessionEnd"),
    ]

    static func showSetup() {
        let settings: [String: Any]
        do {
            settings = try readSettings()
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "MacCove Couldn’t Read Claude Code’s Settings"
            alert.informativeText = "~/.claude/settings.json isn’t valid JSON, so MacCove left it alone. \(error.localizedDescription)"
            alert.runModal()
            return
        }
        let isInstalled = Self.isInstalled(in: settings)

        let alert = NSAlert()
        alert.messageText = "Show Claude Code in MacCove"
        if isInstalled {
            alert.informativeText = """
                Claude Code already runs MacCove’s hook. It has been brought up to date.

                Removing it takes MacCove’s entries out of ~/.claude/settings.json and leaves your other hooks as they are.
                """
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Remove from Claude Code")
        } else {
            alert.informativeText = """
                MacCove adds its hook to ~/.claude/settings.json, so the notch shows what each session is working on, \
                asks you for permission, answers Claude’s questions and approves its plans, and shows when it’s done. \
                Your other hooks stay as they are, and the file is backed up to settings.json.maccove-backup first.

                Anything Claude asks waits for your answer in the notch; after 10 minutes without one, Claude Code asks \
                in the terminal instead. Sessions started from now on use the hook.
                """
            alert.addButton(withTitle: "Add to Claude Code")
            alert.addButton(withTitle: "Cancel")
        }

        do {
            try writeScript()
            // Hooks added since it was installed.
            if isInstalled {
                let updated = adding(to: settings)
                if !NSDictionary(dictionary: updated).isEqual(to: settings) {
                    try save(updated)
                }
            }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            return
        }

        NSApp.activate()
        let choice = alert.runModal()
        do {
            if !isInstalled, choice == .alertFirstButtonReturn {
                try save(adding(to: settings))
            } else if isInstalled, choice == .alertSecondButtonReturn {
                try save(removing(from: settings))
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Settings

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings
    }

    /// Backs up what was there, then writes with sorted keys, so the file
    /// comes out the same each time.
    private static func save(_ settings: [String: Any]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: settingsURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: settingsURL, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func isMacCoveHook(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.hasSuffix("/MacCove/agent-hook.sh") == true
    }

    private static func isInstalled(in settings: [String: Any]) -> Bool {
        let events = settings["hooks"] as? [String: Any] ?? [:]
        return events.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isMacCoveHook)
            }
        }
    }

    /// Every event's groups without MacCove's handlers, dropping groups left
    /// empty.
    private static func removing(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        var events = settings["hooks"] as? [String: Any] ?? [:]
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
        settings["hooks"] = events.isEmpty ? nil : events
        return settings
    }

    private static func adding(to settings: [String: Any]) -> [String: Any] {
        var settings = removing(from: settings)
        var events = settings["hooks"] as? [String: Any] ?? [:]
        let command = scriptURL.path(percentEncoded: false)
        for hook in hooks {
            var handler: [String: Any] = [
                "type": "command",
                "command": command,
                "args": ["claude", hook.name ?? hook.event],
                "timeout": hook.timeout,
            ]
            if hook.isBackground {
                handler["async"] = true
            }
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher = hook.matcher {
                group["matcher"] = matcher
            }
            var groups = events[hook.event] as? [[String: Any]] ?? []
            groups.append(group)
            events[hook.event] = groups
        }
        settings["hooks"] = events
        return settings
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
        # Run by Claude Code's hooks, as set in ~/.claude/settings.json, so MacCove
        # can show the session in the notch. Written by MacCove; changes are
        # replaced the next time you choose Set Up Claude Code.
        #
        # $1 is the agent, $2 the hook event, and the event's JSON comes on stdin.
        # A permission request, and a question or plan (UserInput), wait for
        # MacCove's answer, which is printed for Claude Code. When MacCove isn't
        # running, nothing happens.

        socket="$HOME/Library/Application Support/MacCove/agents.sock"
        [ -S "$socket" ] || exit 0

        wait=5
        case "$2" in PermissionRequest|UserInput) wait=600 ;; esac
        tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')

        curl -sf --max-time "$wait" --unix-socket "$socket" \
          -H 'Expect:' -H 'Content-Type: application/json' \
          -H "X-MacCove-App: ${__CFBundleIdentifier:-}" \
          -H "X-MacCove-TTY: $tty" \
          -H "X-MacCove-PID: $PPID" \
          --data-binary @- "http://maccove/$1/$2" || exit 0

        """#
}
