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

    /// Beside the Xcode scripts. No spaces, so it sources without quoting.
    static var directory: URL {
        URL.libraryDirectory.appending(path: "Scripts/MacCove", directoryHint: .isDirectory)
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
    private static let zshrcMarker = "MacCove/terminal-hook.zsh"
    private static let zshrcLines = """

        # MacCove: show terminal commands that take a while in the island.
        [[ -r "$HOME/Library/Scripts/MacCove/terminal-hook.zsh" ]] && source "$HOME/Library/Scripts/MacCove/terminal-hook.zsh"

        """

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
                ~/Library/Scripts/MacCove. Open a new terminal window afterwards, or run exec zsh.

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

        typeset -g _maccove_threshold_file="$HOME/Library/Scripts/MacCove/terminal-threshold"
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
        # terminal stays in front.
        _maccove_send() {
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
