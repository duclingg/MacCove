//
//  ClaudeCodeSetup.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit

/// Adds MacCove's hook to Claude Code's user settings, or takes it out.
///
/// One script, `agent-hook.sh`, posts each event's JSON to `AgentBridge`
/// with `curl`. Claude Code runs it directly with the agent and event as
/// arguments, so its parent process is Claude Code itself, whose terminal
/// it reports. Most events run in the background and never hold Claude up;
/// a permission request, a question or a finished plan waits for MacCove's
/// answer.
enum ClaudeCodeSetup: AgentSetupProtocol {
    static var scriptURL: URL {
        ScriptsFolder.claudeCode.url.appending(path: "agent-hook.sh")
    }

    /// Where it was before each app's scripts had a folder.
    private static var oldScriptURL: URL {
        ScriptsFolder.unsortedURL(of: "agent-hook.sh")
    }

    /// How a handler's command ends when it's MacCove's, now and before.
    private static let commandSuffix = "/MacCove/ClaudeCode/agent-hook.sh"
    private static let oldCommandSuffix = "/MacCove/agent-hook.sh"

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

    static var hookEvents: [String] {
        var seen: Set<String> = []
        return hooks.map(\.event).filter { seen.insert($0).inserted }
    }

    /// Writes the hook script and adds MacCove's hooks to Claude Code's
    /// settings, or brings an earlier setup up to date with hooks added
    /// since. The file is backed up first, and other hooks stay as they
    /// are. Sessions started from then on use the hook.
    static func setup() {
        guard let settings = readSettingsOrSayWhy() else { return }
        do {
            try writeScript()
            let updated = adding(to: settings)
            if !NSDictionary(dictionary: updated).isEqual(to: settings) {
                try save(updated)
            }
            // Its hooks now run the one in its folder.
            try? FileManager.default.removeItem(at: oldScriptURL)
        } catch {
            NotchGuides.shared.show(.error(id: "claude-setup", icon: .tool(.claudeCode), title: "Couldn’t set up Claude Code", error))
        }
    }

    /// Takes MacCove's hooks back out of Claude Code's settings, leaving
    /// the rest as it was. The script stays, so sessions that are already
    /// open don't run into a missing command; it's rewritten first, so one
    /// from an earlier Set Up also stops once the hooks are gone.
    static func remove() {
        guard let settings = readSettingsOrSayWhy() else { return }
        let updated = removing(from: settings)
        guard !NSDictionary(dictionary: updated).isEqual(to: settings) else { return }
        do {
            if FileManager.default.fileExists(atPath: scriptURL.path(percentEncoded: false)) {
                try writeScript()
            }
            try save(updated)
            // Nothing more comes from the sessions MacCove is showing, so
            // they'd stay as they are.
            NotificationCenter.default.post(name: .agentHooksRemoved, object: AITool.claude)
        } catch {
            NotchGuides.shared.show(.error(id: "claude-setup", icon: .tool(.claudeCode), title: "Couldn’t take out Claude Code’s hooks", error))
        }
    }

    // MARK: - Claude Code itself

    /// Where Claude Code's installers put the `claude` command: the native
    /// installer, the older local install, and npm or Homebrew.
    private static var commandURLs: [URL] {
        [
            URL.homeDirectory.appending(path: ".local/bin/claude"),
            URL.homeDirectory.appending(path: ".claude/local/claude"),
            URL(filePath: "/opt/homebrew/bin/claude"),
            URL(filePath: "/usr/local/bin/claude"),
        ]
    }

    /// Whether Claude Code is on this Mac: its `claude` command is in one
    /// of the usual places. Hooks set up without it would never run.
    static func isInstalled() -> Bool {
        commandURLs.contains { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    // MARK: - Settings

    /// Whether Claude Code runs MacCove's hook. Quietly `false` when its
    /// settings can't be read, since this is asked every time the
    /// settings pane draws; Set Up says what's wrong.
    /// Hooks that still run the script from before it had a folder don't
    /// count, so Set Up shows and moves them.
    static func hooksSetup() -> Bool {
        guard let settings = try? readSettings() else { return false }
        let events = settings["hooks"] as? [String: Any] ?? [:]
        return events.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { handler in
                    (handler["command"] as? String)?.hasSuffix(commandSuffix) == true
                }
            }
        }
    }

    /// Claude Code's settings, or `nil` once it has said they aren't valid
    /// JSON, which MacCove won't overwrite.
    private static func readSettingsOrSayWhy() -> [String: Any]? {
        do {
            return try readSettings()
        } catch {
            NotchGuides.shared.show(.notice(
                id: "claude-setup",
                icon: .tool(.claudeCode),
                title: "Couldn’t read Claude Code’s settings",
                message: "~/.claude/settings.json isn’t valid JSON, so MacCove left it alone. \(error.localizedDescription)",
                tone: .error
            ))
            return nil
        }
    }

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

    /// Either script, so Set Up and Remove also take out hooks from
    /// before it had a folder.
    private static func isMacCoveHook(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        return command.hasSuffix(commandSuffix) || command.hasSuffix(oldCommandSuffix)
    }

    /// Every event's groups without MacCove's handlers, dropping groups left empty.
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
        #
        # Claude Code keeps the hooks a session started with, so after Remove
        # Claude Code an open session still runs this. It does nothing once
        # the hook is no longer in the settings.

        grep -qF '/MacCove/ClaudeCode/agent-hook.sh' "$HOME/.claude/settings.json" 2>/dev/null || exit 0

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
