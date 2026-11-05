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

    /// Set Up: writes the hook (again, in case it's changed) and adds the
    /// two lines that load it to the end of ~/.zshrc, after backing it up.
    /// Clicking Set Up is the go-ahead, so there's nothing to confirm.
    /// Shells already open don't have it yet, so the notch finishes the
    /// setup: open a new window, or run exec zsh.
    static func setUp() {
        do {
            try install()
            let zshrc = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
            if zshrc.contains(zshrcMarker) {
                // Already loaded from its folder: the hook's just up to date.
                return
            }
            if zshrc.contains(oldZshrcMarker) {
                try moveFromOldFolder(zshrc)
            } else {
                try addToZshrc()
            }
        } catch {
            NotchGuides.shared.show(.error(id: reloadGuideID, icon: .tool(.terminal), title: "Couldn’t set up Terminal", error))
            return
        }
        showReloadGuide()
    }

    static let reloadGuideID = "terminal-reload"

    private static func showReloadGuide() {
        NotchGuides.shared.show(NotchGuide(
            id: reloadGuideID,
            icon: .tool(.terminal),
            title: "Open a new terminal window",
            subtitle: "Shells that are open don’t load the hook yet",
            steps: [
                NotchGuide.Step(id: "added", text: "Added to ~/.zshrc", detail: "Backed up beside it first", isDone: true),
                NotchGuide.Step(id: "loaded", text: "Open a new window, or run exec zsh", detail: "Ticks off with the first command of \(threshold) s or more", isWatching: true),
            ],
            actions: [
                NotchGuide.Action(title: "Copy exec zsh", finishes: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("exec zsh", forType: .string)
                },
                NotchGuide.Action(title: "Done", isPrimary: true) {},
            ]
        ))
    }

    /// A command reported in, so a shell has the hook: the guide ticks it
    /// off, then leaves.
    static func commandArrived() {
        let guides = NotchGuides.shared
        guard guides.isShowing(reloadGuideID) else { return }
        guides.complete(step: "loaded", in: reloadGuideID)
        Task {
            try? await Task.sleep(for: .seconds(3))
            guides.finish(reloadGuideID)
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
    private static func moveFromOldFolder(_ zshrc: String) throws {
        try backUpAndWrite(zshrc.replacingOccurrences(of: oldHookPath, with: hookPath))
        removeOldFiles()
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
            NotchGuides.shared.show(.error(id: reloadGuideID, icon: .tool(.terminal), title: "Couldn’t take MacCove out of ~/.zshrc", error))
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
