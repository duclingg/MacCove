import SwiftUI

/// The design's prompt, `>_`, drawn in a 24pt box. The island's own,
/// rather than the icon of the app the command ran in, which may come to
/// have an activity of its own.
nonisolated private struct PromptShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 5, y: 7))
        path.addLine(to: CGPoint(x: 10, y: 12))
        path.addLine(to: CGPoint(x: 5, y: 17))
        path.move(to: CGPoint(x: 12.5, y: 17.5))
        path.addLine(to: CGPoint(x: 19, y: 17.5))
        let scale = min(rect.width, rect.height) / 24
        return path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.midX - 12 * scale, dy: rect.midY - 12 * scale)
    }
}

private struct TerminalGlyph: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        PromptShape()
            .stroke(color, style: StrokeStyle(lineWidth: 2.2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// White, or red once a command has failed, as in the pill and bubbles.
private func glyphColor(_ command: TerminalCommandMonitor.Command?) -> Color {
    if case .failed? = command?.phase { return .islandError }
    return .white
}

/// "1:24" up to an hour, then "1:02:03".
private func commandClock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    let minutes = String(format: "%02d", seconds / 60 % 60)
    let rest = String(format: "%02d", seconds % 60)
    return seconds >= 3600 ? "\(seconds / 3600):\(minutes):\(rest)" : "\(seconds / 60):\(rest)"
}

/// "48s", "2m 14s", "1h 3m".
private func commandDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    if seconds >= 3600 { return "\(seconds / 3600)h \(seconds / 60 % 60)m" }
    if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds)s"
}

/// With your home folder as ~, as the prompt shows it.
private func abbreviatedFolder(_ path: String) -> String {
    let home = URL.homeDirectory.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !home.isEmpty, trimmed == home || trimmed.hasPrefix(home + "/") else { return path }
    return "~" + trimmed.dropFirst(home.count)
}

/// The prompt glyph in the left wing. In the right: the time so far
/// while it runs, a green check once it's done, or the exit code in red.
struct TerminalCompactView: View {
    let terminal: TerminalCommandMonitor
    let notchSize: CGSize

    /// Each wing of the pill while there's text on the right: room for
    /// "12:34" or "exit 127".
    static let textWingWidth: CGFloat = 64

    static func width(for command: TerminalCommandMonitor.Command?, notch: CGSize) -> CGFloat {
        guard command?.phase == .finished else {
            return notch.width + textWingWidth * 2
        }
        return NotchViewModel.compactWidth(notch: notch)
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let command = terminal.command

        HStack(spacing: 0) {
            TerminalGlyph(color: glyphColor(command), size: layout.artSize)
            Spacer(minLength: 0)
            if let command {
                trailing(command, size: layout.artSize)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, layout.sideInset)
        .frame(width: Self.width(for: command, notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.map { Self.accessibilityDescription($0) } ?? "Terminal")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func trailing(_ command: TerminalCommandMonitor.Command, size: CGFloat) -> some View {
        switch command.phase {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(commandClock(context.date.timeIntervalSince(command.startedAt)))
            }
        case .finished:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.islandSucceeded)
                .frame(width: size, height: size)
        case let .failed(exitCode):
            Text("exit \(exitCode)")
                .foregroundStyle(Color.islandError)
        }
    }

    private static func accessibilityDescription(_ command: TerminalCommandMonitor.Command) -> String {
        switch command.phase {
        case .running: "Running \(command.text)"
        case .finished: "\(command.text) finished"
        case let .failed(exitCode): "\(command.text) failed with exit code \(exitCode)"
        }
    }
}

/// The terminal in a bubble beside another activity: just the prompt.
struct TerminalMinimalView: View {
    let terminal: TerminalCommandMonitor
    let notchSize: CGSize

    var body: some View {
        TerminalGlyph(color: glyphColor(terminal.command), size: BubbleLayout(notch: notchSize).artSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Terminal")
            .accessibilityAddTraits(.isButton)
    }
}

/// Opened up; the glyph shows its terminal. The command, its folder and,
/// while it runs, the time so far with Stop; once it's done, how long it
/// took or its exit code, with Dismiss and Show in Terminal.
struct TerminalExpandedView: View {
    let terminal: TerminalCommandMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    /// The buttons only show once it's done.
    static func bodyHeight(for command: TerminalCommandMonitor.Command?) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        if let command, command.phase != .running {
            height += chipsGap + chipHeight
        }
        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            if let command = terminal.command {
                header(command)
                if command.phase != .running {
                    buttons
                        .padding(.top, Self.chipsGap)
                }
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private func header(_ command: TerminalCommandMonitor.Command) -> some View {
        HStack(spacing: 12) {
            Button {
                terminal.showInTerminal()
            } label: {
                // On a tile, green too once it's finished.
                TerminalGlyph(color: command.phase == .finished ? .islandSucceeded : glyphColor(command), size: 26)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show in Terminal")

            VStack(alignment: .leading, spacing: 0) {
                Text(command.text)
                    .font(.system(size: 15, weight: .semibold))
                    .truncationMode(.tail)
                Text(Self.subtitle(command))
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if command.phase == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(commandClock(context.date.timeIntervalSince(command.startedAt)))
                        .font(.system(size: 28))
                        .monospacedDigit()
                        .tracking(-0.5)
                }
                Button {
                    terminal.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.islandError)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.islandError.opacity(0.18)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
        }
        .frame(height: Self.headerHeight)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            chip("Dismiss", background: .white.opacity(0.12), foreground: .white) {
                terminal.dismiss()
            }
            chip("Show in Terminal", background: .white, foreground: Color(red: 20 / 255, green: 20 / 255, blue: 19 / 255)) {
                terminal.showInTerminal()
            }
        }
    }

    private func chip(_ label: String, background: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// "~/Developer/site · zsh" while it runs, then "Finished in 2m 14s ·
    /// ~/Developer/site" or "Exit code 1 after 48s · ~/Developer/site".
    private static func subtitle(_ command: TerminalCommandMonitor.Command) -> String {
        let folder = abbreviatedFolder(command.directory)
        let took = command.duration.map(commandDuration) ?? ""
        switch command.phase {
        case .running: return "\(folder) · zsh"
        case .finished: return "Finished in \(took) · \(folder)"
        case let .failed(exitCode): return "Exit code \(exitCode) after \(took) · \(folder)"
        }
    }
}
