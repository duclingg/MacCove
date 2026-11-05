//
//  AutomationPermission.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

/// Asking macOS to let MacCove control another app over Apple Events:
/// Music, Xcode, Terminal and iTerm. Each is asked for when what needs it
/// is set up, in the welcome or Settings, never by itself later.
enum AutomationPermission {
    /// Never asks. An app has to be open to tell, so it's Not Asked until
    /// then.
    static func status(of bundleIdentifier: String) async -> OnboardingAccess {
        access(for: await determine(bundleIdentifier, asking: false))
    }

    /// Brings up macOS's prompt, unless it's been answered already. Only an
    /// open app can be asked about: with `openingHidden`, one that isn't
    /// open is opened hidden in the background first; otherwise it's left
    /// Not Asked.
    static func request(_ bundleIdentifier: String, openingHidden: Bool) async -> OnboardingAccess {
        if !isRunning(bundleIdentifier) {
            guard openingHidden,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return .notAsked
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            // Up to five seconds for it to finish opening.
            for _ in 0..<25 {
                if isRunning(bundleIdentifier) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return access(for: await determine(bundleIdentifier, asking: true))
    }

    static func isRunning(_ bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains(where: \.isFinishedLaunching)
    }

    static func openSettings() {
        SystemSettings.openPrivacy("Privacy_Automation")
    }

    private static func access(for status: OSStatus) -> OnboardingAccess {
        switch status {
        case OSStatus(noErr): .allowed
        case OSStatus(errAEEventWouldRequireUserConsent), OSStatus(procNotFound): .notAsked
        default: .denied
        }
    }

    /// Blocks until macOS has its answer, so it's off the main thread.
    private static func determine(_ bundleIdentifier: String, asking: Bool) async -> OSStatus {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), asking)
        }.value
    }
}
