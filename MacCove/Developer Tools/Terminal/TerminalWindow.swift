//
//  TerminalWindow.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit
import CoreServices

/// Brings forward the window a command ran in. Terminal and iTerm say
/// which tab has which terminal device over Apple Events, so their exact
/// tab comes forward; any other app (Ghostty, Warp, VS Code…) is just
/// brought to the front.
enum TerminalWindow {
    private static let terminal = "com.apple.Terminal"
    private static let iTerm = "com.googlecode.iterm2"

    /// Whether the app can say which of its tabs is in front.
    static func knowsTabs(_ appBundleIdentifier: String) -> Bool {
        appBundleIdentifier == terminal || appBundleIdentifier == iTerm
    }

    /// The terminal device of the tab in front in Terminal or iTerm, or
    /// `nil` when it can't say. Only asks once MacCove may control that
    /// terminal, given the first time a window was brought forward, so
    /// this never prompts by itself.
    static func frontTTY(of appBundleIdentifier: String) -> String? {
        let source = switch appBundleIdentifier {
        case terminal: "tell application id \"\(terminal)\" to get tty of selected tab of front window"
        case iTerm: "tell application id \"\(iTerm)\" to get tty of current session of current window"
        default: ""
        }
        guard !source.isEmpty, mayControl(appBundleIdentifier) else { return nil }
        var error: NSDictionary?
        let tty = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        return error == nil ? tty : nil
    }

    /// Set Up asks to control Terminal and iTerm, whichever are open, so
    /// bringing a window forward later doesn't. One that isn't open asks
    /// the first time a window of it is brought forward.
    static func askToControl() async {
        for app in [terminal, iTerm] where AutomationPermission.isRunning(app) {
            _ = await AutomationPermission.request(app, openingHidden: false)
        }
    }

    private static func mayControl(_ appBundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: appBundleIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        return status == OSStatus(noErr)
    }

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

    /// Presses Esc in the terminal a command runs in, as if typed there.
    /// iTerm takes it over Apple Events without coming forward; any other
    /// app is brought forward and sent the key, which needs Accessibility
    /// access. Returns false when it couldn't be sent: the window is still
    /// brought forward, so Esc can be pressed there.
    @discardableResult
    static func pressEscape(appBundleIdentifier: String?, tty: String?) -> Bool {
        guard let appBundleIdentifier else { return false }
        if appBundleIdentifier == iTerm, let tty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: iTerm).isEmpty {
            var error: NSDictionary?
            let sent = NSAppleScript(source: escapeScript(tty: tty))?.executeAndReturnError(&error)
            if error == nil, sent?.booleanValue == true { return true }
        }
        bringForward(appBundleIdentifier: appBundleIdentifier, tty: tty)
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            return false
        }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).first?.processIdentifier else {
            return false
        }
        // Once the window has come forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let escape: CGKeyCode = 53 // kVK_Escape
            for isDown in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: isDown)?.postToPid(pid)
            }
        }
        return true
    }

    private static func escapeScript(tty: String) -> String {
        """
        tell application id "\(iTerm)"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if tty of aSession is "\(quote(tty))" then
                            tell aSession to write text (character id 27) newline no
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    private static func quote(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func script(for appBundleIdentifier: String, tty: String) -> String? {
        let quoted = quote(tty)
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
