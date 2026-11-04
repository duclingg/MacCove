//
//  TerminalHook.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit

/// The zsh hook that reports long commands to `TerminalCommandMonitor`.
///
/// It lives in its own file, which ~/.zshrc sources, so MacCove can rewrite
/// it without touching your shell setup again. `preexec` starts a timer in
/// the background as each command starts; only a command still running
/// when the timer ends is reported, so quicker ones cost nothing but that
/// timer and never reach MacCove. `precmd` reports the end and exit code
/// of those that were. Neither waits on MacCove, so the prompt never does.
enum TerminalHook {
    /// Choices in the menu, in seconds.
    static let thresholdOptions = [5, 10, 30, 60]
    static let defaultThreshold = 10
    static let thresholdKey = "TerminalCommandThreshold"

    static var directory: URL {
        ScriptsFolder.terminal.url
    }

    private static var hookURL: URL {
        directory.appending(path: "terminal-hook.zsh")
    }

    /// Read by the hook as each command starts, so a new threshold applies
    /// straight away, without opening a new shell.
    private static var thresholdURL: URL {
        directory.appending(path: "terminal-threshold")
    }

    private static var zshrcURL: URL {
        URL.homeDirectory.appending(path: ".zshrc")
    }

    /// What MacCove adds to ~/.zshrc, and how it knows it already has.
    private static let zshrcMarker = "MacCove/Terminal/terminal-hook.zsh"
    private static let hookPath = "$HOME/Library/Scripts/MacCove/Terminal/terminal-hook.zsh"
    private static let zshrcLines = lines(loading: hookPath)

    /// The same, from before each app's scripts had a folder: the hook was
    /// straight in ~/Library/Scripts/MacCove.
    private static let oldZshrcMarker = "MacCove/terminal-hook.zsh"
    private static let oldHookPath = "$HOME/Library/Scripts/MacCove/terminal-hook.zsh"
    private static let oldZshrcLines = lines(loading: oldHookPath)

    private static func lines(loading path: String) -> String {
        """

        # MacCove: show terminal commands that take a while in the island.
        [[ -r "\(path)" ]] && source "\(path)"

        """
    }

    static var threshold: Int {
        let stored = UserDefaults.standard.integer(forKey: thresholdKey)
        return stored > 0 ? stored : defaultThreshold
    }

    static func setThreshold(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: thresholdKey)
        try? writeThreshold()
    }

    /// Writes the hook (again, in case it's changed), then offers to add
    /// the line that loads it to ~/.zshrc.
    static func showSetup() {
        do {
            try install()
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            return
        }

        let zshrc = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        let isAdded = zshrc.contains(zshrcMarker)
        if !isAdded, zshrc.contains(oldZshrcMarker) {
            moveFromOldFolder(zshrc)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Show Long Terminal Commands in the Island"
        let about = """
            Commands that run for \(threshold) seconds or more show in the island while they run, \
            then pop up when they finish if their terminal is in the background. Only the command, \
            its folder and its exit code reach MacCove, never its output.
            """
        if isAdded {
            alert.informativeText = about + "\n\n~/.zshrc already loads MacCove’s hook. It’s up to date."
            alert.addButton(withTitle: "OK")
        } else {
            alert.informativeText = about + """


                MacCove adds two lines to the end of ~/.zshrc to load its hook from \
                \(ScriptsFolder.terminal.displayPath). Open a new terminal window afterwards, or run exec zsh.

                Show in Terminal asks to let MacCove control Terminal or iTerm the first time.
                """
            alert.addButton(withTitle: "Add to .zshrc")
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, !isAdded else { return }

        do {
            try addToZshrc()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// ~/.zshrc loads MacCove's hook from its folder. A line that still
    /// loads it from where it was before doesn't count, so Set Up shows
    /// and moves it.
    static func isInstalled() -> Bool {
        let zshrc = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        return zshrc.contains(zshrcMarker)
    }

    /// Points ~/.zshrc's line at the hook in its own folder, and deletes
    /// the one straight in ~/Library/Scripts/MacCove. The hook was just
    /// written there by `install()`.
    private static func moveFromOldFolder(_ zshrc: String) {
        do {
            try backUpAndWrite(zshrc.replacingOccurrences(of: oldHookPath, with: hookPath))
            removeOldFiles()
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "MacCove’s Terminal Hook Moved"
        alert.informativeText = """
            Its scripts now have a folder for each app, so ~/.zshrc loads the hook from \
            \(ScriptsFolder.terminal.displayPath) instead. Your ~/.zshrc was backed up beside itself first. \
            Open a new terminal window, or run exec zsh, to load it from there.
            """
        NSApp.activate()
        alert.runModal()
    }

    /// Through any symlink, so dotfiles kept elsewhere stay linked, after
    /// copying what was there to .zshrc.maccove-backup beside it.
    private static func backUpAndWrite(_ zshrc: String) throws {
        let fileManager = FileManager.default
        let url = zshrcURL.resolvingSymlinksInPath()
        let backupURL = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".maccove-backup")
        try? fileManager.removeItem(at: backupURL)
        try fileManager.copyItem(at: url, to: backupURL)
        try zshrc.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func removeOldFiles() {
        for name in ["terminal-hook.zsh", "terminal-threshold"] {
            try? FileManager.default.removeItem(at: ScriptsFolder.unsortedURL(of: name))
        }
    }

    /// Takes out what Set Up added to ~/.zshrc, after backing it up beside
    /// itself, and deletes the hook. Shells already open have the hook
    /// loaded, but it stops reporting once its file is gone.
    static func remove() {
        let fileManager = FileManager.default
        do {
            if let zshrc = try? String(contentsOf: zshrcURL.resolvingSymlinksInPath(), encoding: .utf8),
               zshrc.contains(zshrcMarker) || zshrc.contains(oldZshrcMarker) {
                try backUpAndWrite(removingLines(from: zshrc))
            }
            try? fileManager.removeItem(at: hookURL)
            try? fileManager.removeItem(at: thresholdURL)
            try? fileManager.removeItem(at: directory)
            removeOldFiles()
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    /// What Set Up appended, exactly; or, if it's been edited since, any
    /// line that loads the hook and the comment above it.
    private static func removingLines(from zshrc: String) -> String {
        let exact = zshrc
            .replacingOccurrences(of: zshrcLines, with: "")
            .replacingOccurrences(of: oldZshrcLines, with: "")
        guard exact.contains(zshrcMarker) || exact.contains(oldZshrcMarker) else { return exact }
        let comment = zshrcLines.split(separator: "\n").first.map(String.init) ?? ""
        return exact
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(zshrcMarker) && !$0.contains(oldZshrcMarker) && $0 != comment }
            .joined(separator: "\n")
    }

    private static func install() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try hook.write(to: hookURL, atomically: true, encoding: .utf8)
        try writeThreshold()
    }

    private static func writeThreshold() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "\(threshold)\n".write(to: thresholdURL, atomically: true, encoding: .utf8)
    }

    /// Appends, through any symlink, so a ~/.zshrc kept with your dotfiles
    /// stays where it is.
    private static func addToZshrc() throws {
        guard FileManager.default.fileExists(atPath: zshrcURL.path(percentEncoded: false)) else {
            try zshrcLines.write(to: zshrcURL, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: zshrcURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(zshrcLines.utf8))
    }

    private static let hook = #"""
        # MacCove: shows terminal commands that take a while in the island.
        # Written by MacCove; changes are replaced the next time you choose
        # Set Up Terminal Commands. Commands quicker than the threshold never
        # reach MacCove, and no command's output is ever read.

        [[ -o interactive ]] || return 0
        zmodload zsh/datetime 2>/dev/null || return 0
        autoload -Uz add-zsh-hook

        typeset -g _maccove_hook_file="$HOME/Library/Scripts/MacCove/Terminal/terminal-hook.zsh"
        typeset -g _maccove_threshold_file="$HOME/Library/Scripts/MacCove/Terminal/terminal-threshold"
        typeset -g _maccove_id= _maccove_cmd= _maccove_dir= _maccove_start= _maccove_timer=
        typeset -g _maccove_threshold=10

        # Percent-encodes $1 for a URL, byte by byte.
        _maccove_encode() {
          emulate -L zsh
          local LC_ALL=C hex out=
          local -i i
          for (( i = 1; i <= ${#1}; i++ )); do
            case ${1[i]} in
              [a-zA-Z0-9._~/-]) out+=${1[i]} ;;
              *) printf -v hex '%%%02X' "'${1[i]}"; out+=$hex ;;
            esac
          done
          print -rn -- $out
        }

        # Only when MacCove is running, and in the background with -g, so the
        # terminal stays in front. Not once Remove has deleted this file, so
        # shells that loaded it earlier stop reporting too.
        _maccove_send() {
          [[ -r $_maccove_hook_file ]] || return 0
          pgrep -xq MacCove || return 0
          open -g "maccove://terminal/$1?id=$_maccove_id&pid=$$&start=$_maccove_start&app=${__CFBundleIdentifier:-}&tty=$(_maccove_encode "${TTY:-}")&dir=$(_maccove_encode "$_maccove_dir")&cmd=$(_maccove_encode "${_maccove_cmd[1,300]}")$2"
        }

        _maccove_preexec() {
          _maccove_cmd=$1
          _maccove_dir=$PWD
          _maccove_start=$EPOCHREALTIME
          _maccove_id="$$-${EPOCHREALTIME/./}"
          local threshold=
          [[ -r $_maccove_threshold_file ]] && threshold=$(<$_maccove_threshold_file)
          [[ $threshold == <-> ]] && _maccove_threshold=$threshold || _maccove_threshold=10
          ( sleep $_maccove_threshold; _maccove_send started ) &!
          _maccove_timer=$!
        }

        _maccove_precmd() {
          local exit_status=$?
          [[ -n $_maccove_start ]] || return 0
          kill $_maccove_timer 2>/dev/null
          if (( EPOCHREALTIME - _maccove_start >= _maccove_threshold )); then
            _maccove_send finished "&status=$exit_status" &!
          fi
          _maccove_start=
          return 0
        }

        add-zsh-hook preexec _maccove_preexec
        # First, so it sees the command's exit status before other hooks
        # change it.
        precmd_functions=(_maccove_precmd ${precmd_functions:#_maccove_precmd})

        """#
}
