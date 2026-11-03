import AppKit

/// Terminal commands that take a while, as the island shows them: running,
/// then finished or failed.
///
/// A zsh hook (see `TerminalHook`) reports each command once it has run
/// for the threshold, 10 seconds unless changed, and again when it ends,
/// through maccove://terminal/… URLs that land in `handle(_:)`. Quicker
/// commands never reach MacCove. The command's output is never seen, only
/// its text, folder, start time and exit code.
@Observable
final class TerminalCommandMonitor {
    enum Event {
        case started
        case finished
        case failed
        /// Dismissed, interrupted, or its shell went away.
        case ended
    }

    enum Phase: Equatable {
        case running
        case finished
        case failed(exitCode: Int32)
    }

    struct Command: Equatable, Identifiable {
        /// The shell's process and the command's start, from the hook.
        let id: String
        let text: String
        let directory: String
        let shellPID: pid_t?
        /// The shell's terminal device, which Terminal and iTerm find its
        /// window by.
        let tty: String?
        /// The app the shell runs in: Terminal, iTerm, Ghostty, VS Code…
        let appBundleIdentifier: String?
        let startedAt: Date
        var finishedAt: Date?
        var phase: Phase

        var duration: TimeInterval? {
            finishedAt.map { $0.timeIntervalSince(startedAt) }
        }
    }

    /// The command being shown, `nil` when there's none.
    private(set) var command: Command?

    @ObservationIgnored var onEvent: ((Event) -> Void)?

    /// Commands still running, the shown one among them, by id.
    @ObservationIgnored private var running: [String: Command] = [:]
    /// Ended commands, so a start report that loses the race with its own
    /// end doesn't bring one back.
    @ObservationIgnored private var endedIDs: Set<String> = []
    @ObservationIgnored private var shellCheck: Task<Void, Never>?

    /// What ^C leaves: the command was stopped on purpose, not failed.
    private static let interruptedExitCode: Int32 = 130
    /// How often running commands' shells are checked, in case a terminal
    /// window was closed mid-command and no end will ever come.
    private static let shellCheckInterval: Duration = .seconds(5)

    /// Full-screen programs and prompts you're in the middle of using, which
    /// run as long as you keep them open. Matched against the command's
    /// first word.
    private static let interactivePrograms: Set<String> = [
        "vi", "vim", "nvim", "nano", "emacs", "micro", "hx", "helix",
        "ssh", "mosh", "telnet", "sftp", "ftp",
        "top", "htop", "btop", "less", "more", "most", "man",
        "tmux", "screen", "zellij", "watch", "fzf", "lazygit", "tig", "ranger", "nnn",
        "claude", "codex", "aider", "gemini",
        "sudoedit", "crontab", "visudo",
    ]
    /// Interactive only without arguments, when they start a prompt.
    private static let interactiveWithoutArguments: Set<String> = [
        "python", "python3", "node", "irb", "ruby", "swift", "ghci", "lua", "bc",
        "psql", "mysql", "sqlite3", "redis-cli", "mongosh", "zsh", "bash", "fish", "sh",
    ]

    /// Returns whether the URL was one of the hook's.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "maccove", url.host() == "terminal" else { return false }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard let id = query["id"], !id.isEmpty,
              let text = query["cmd"], !text.isEmpty,
              !Self.isInteractive(text) else { return true }

        switch url.lastPathComponent {
        case "started":
            commandStarted(Self.command(id: id, text: text, query: query))
        case "finished":
            commandFinished(id: id, exitCode: Int32(query["status"] ?? "") ?? 0, fallback: Self.command(id: id, text: text, query: query))
        default:
            break
        }
        return true
    }

    /// Leaves the island, and a command still running elsewhere takes its
    /// place.
    func dismiss() {
        guard let shown = command else { return }
        running[shown.id] = nil
        command = running.values.max { $0.startedAt < $1.startedAt }
        onEvent?(.ended)
    }

    /// Brings the command's window forward. A result has been seen once
    /// you're back in its terminal, so it leaves too.
    func showInTerminal() {
        guard let shown = command else { return }
        TerminalWindow.bringForward(appBundleIdentifier: shown.appBundleIdentifier, tty: shown.tty)
        if shown.phase != .running {
            dismiss()
        }
    }

    // MARK: - Reports from the hook

    /// The newest command takes the island, over a result still showing.
    private func commandStarted(_ started: Command) {
        guard !endedIDs.contains(started.id), running[started.id] == nil else { return }
        running[started.id] = started
        command = started
        onEvent?(.started)
        watchShells()
    }

    /// Pops up only when the command's terminal is in the background, as
    /// in front you've seen it end. ^C just ends it.
    private func commandFinished(id: String, exitCode: Int32, fallback: Command) {
        endedIDs.insert(id)
        var finished = running.removeValue(forKey: id) ?? fallback
        finished.finishedAt = .now

        let isTerminalInFront = finished.appBundleIdentifier != nil
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finished.appBundleIdentifier
        guard exitCode != Self.interruptedExitCode, !isTerminalInFront else {
            if command?.id == id {
                dismiss()
            }
            return
        }

        finished.phase = exitCode == 0 ? .finished : .failed(exitCode: exitCode)
        command = finished
        onEvent?(exitCode == 0 ? .finished : .failed)
    }

    /// A shell that has gone, with its window, takes its running command
    /// with it.
    private func watchShells() {
        guard shellCheck == nil else { return }
        shellCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.shellCheckInterval)
                guard let self, !self.running.isEmpty else { break }
                for (id, command) in self.running {
                    guard let pid = command.shellPID, kill(pid, 0) != 0, errno == ESRCH else { continue }
                    self.running[id] = nil
                    self.endedIDs.insert(id)
                    if self.command?.id == id {
                        self.dismiss()
                    }
                }
            }
            self?.shellCheck = nil
        }
    }

    // MARK: - Parsing

    private static func command(id: String, text: String, query: [String: String]) -> Command {
        let start = Double(query["start"] ?? "").map { Date(timeIntervalSince1970: $0) } ?? .now
        return Command(
            id: id,
            text: text,
            directory: query["dir"] ?? "",
            shellPID: query["pid"].flatMap { pid_t($0) },
            tty: query["tty"].flatMap { $0.isEmpty ? nil : $0 },
            appBundleIdentifier: query["app"].flatMap { $0.isEmpty ? nil : $0 },
            startedAt: start,
            phase: .running
        )
    }

    /// The program the command runs, past `sudo`, `env`, `time` and
    /// variable assignments.
    private static func isInteractive(_ text: String) -> Bool {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first,
              ["sudo", "env", "time", "nohup", "command", "exec"].contains(first) || (first.contains("=") && !first.hasPrefix("=")) {
            words.removeFirst()
        }
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
        if interactivePrograms.contains(program) { return true }
        if interactiveWithoutArguments.contains(program), words.count == 1 { return true }
        // Following a file never ends by itself.
        if program == "tail", words.contains(where: { $0 == "-f" || $0 == "-F" }) { return true }
        return false
    }
}

#if DEBUG
extension TerminalCommandMonitor {
    /// A command that stays as given, for SwiftUI previews.
    static func preview(_ command: Command) -> TerminalCommandMonitor {
        let monitor = TerminalCommandMonitor()
        monitor.command = command
        return monitor
    }
}
#endif
