import AppKit

/// Brings forward the window a command ran in. Terminal and iTerm say
/// which tab has which terminal device over Apple Events, so their exact
/// tab comes forward; any other app (Ghostty, Warp, VS Code…) is just
/// brought to the front.
enum TerminalWindow {
    private static let terminal = "com.apple.Terminal"
    private static let iTerm = "com.googlecode.iterm2"

    static func bringForward(appBundleIdentifier: String?, tty: String?) {
        guard let appBundleIdentifier else { return }
        if let tty, let source = script(for: appBundleIdentifier, tty: tty),
           !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).isEmpty {
            // Quick, and NSAppleScript wants the main thread. The first time
            // asks to let MacCove control that terminal.
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error == nil { return }
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private static func script(for appBundleIdentifier: String, tty: String) -> String? {
        let quoted = tty
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        switch appBundleIdentifier {
        case terminal:
            return """
                tell application id "\(terminal)"
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            if tty of aTab is "\(quoted)" then
                                set selected tab of aWindow to aTab
                                set index of aWindow to 1
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
                """
        case iTerm:
            return """
                tell application id "\(iTerm)"
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            repeat with aSession in sessions of aTab
                                if tty of aSession is "\(quoted)" then
                                    select aWindow
                                    select aTab
                                    select aSession
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
                """
        default:
            return nil
        }
    }
}
