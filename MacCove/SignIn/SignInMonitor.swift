import AppKit
import ApplicationServices

/// The system's Touch ID prompts and the lock screen, as the island shows
/// them: waiting for a finger, then unlocked.
///
/// macOS doesn't announce these prompts, so their windows are watched for.
/// SecurityAgent draws the ones for admin rights and System Settings, and
/// coreautha the LocalAuthentication ones that apps and `sudo` ask for.
/// Seeing a prompt needs no permission. Telling unlocking apart from giving
/// up needs Accessibility access, to find the prompt's Cancel button and
/// notice a click on it or Escape. Without it the island leaves quietly
/// with the prompt. Escape can't be seen while the password field has
/// focus, since macOS keeps typing there from every other app.
///
/// The lock screen counts too: locking shows Touch ID, and unlocking, by
/// either method, plays the unlock.
///
/// Nothing tells other apps when a finger is on the sensor, so the
/// fingerprint can't react to the touch itself, only to the result.
@Observable
final class SignInMonitor {
    enum Prompt: Equatable {
        case touchID
        case unlocked
    }

    private(set) var prompt: Prompt?
    private(set) var hasAccessibilityAccess = AXIsProcessTrusted()

    @ObservationIgnored var onChange: ((Prompt?) -> Void)?

    /// The processes that draw the prompts, by the name their windows give.
    private static let agentNames: Set<String> = ["SecurityAgent", "coreautha"]
    /// Twice a second while nothing is up, and ten times a second while a
    /// prompt is, so the unlock shows as soon as it closes.
    private static let idleInterval: Duration = .milliseconds(500)
    private static let activeInterval: Duration = .milliseconds(100)
    private static let unlockedDuration: Duration = .seconds(1.6)
    private static let escapeKeyCode: UInt16 = 53

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var unlockTask: Task<Void, Never>?
    @ObservationIgnored private var eventMonitors: [Any] = []
    /// The agent showing the open prompt, `nil` while there isn't one.
    @ObservationIgnored private var promptPID: pid_t?
    /// In Accessibility's coordinates: from the top left of the main display.
    @ObservationIgnored private var cancelButtonFrame: CGRect?
    @ObservationIgnored private var wasCancelled = false
    @ObservationIgnored private var isScreenLocked = false
    @ObservationIgnored private var lockObservers: [NSObjectProtocol] = []

    func start() {
        // Posted by loginwindow to every app as the screen locks and unlocks.
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLockChanged(locked: locked) }
            })
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.check() else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Shows the system's request for Accessibility access, which opens
    /// System Settings at the right place.
    func requestAccessibilityAccess() {
        // The `kAXTrustedCheckOptionPrompt` global isn't concurrency-safe
        // in Swift 6; this is its value.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        hasAccessibilityAccess = AXIsProcessTrustedWithOptions(options)
    }

    private func check() -> Duration {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibilityAccess {
            hasAccessibilityAccess = trusted
        }
        // The lock screen reports itself; no prompt shows over it.
        guard !isScreenLocked else { return Self.idleInterval }
        guard let pid = Self.promptWindowOwner() else {
            promptClosed()
            return Self.idleInterval
        }
        promptOpen(pid: pid)
        return Self.activeInterval
    }

    private func promptOpen(pid: pid_t) {
        if promptPID == nil {
            unlockTask?.cancel()
            wasCancelled = false
            if hasAccessibilityAccess {
                watchForCancel()
            }
        }
        promptPID = pid
        if hasAccessibilityAccess {
            cancelButtonFrame = Self.cancelButtonFrame(pid: pid)
        }
        setPrompt(.touchID)
    }

    private func promptClosed() {
        guard promptPID != nil else { return }
        stopWatchingPrompt()
        if prompt == .touchID, hasAccessibilityAccess, !wasCancelled {
            showUnlocked()
        } else {
            setPrompt(nil)
        }
    }

    /// The screen locking replaces any prompt that was open; unlocking can
    /// only mean the password or Touch ID was accepted.
    private func screenLockChanged(locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        guard locked else {
            showUnlocked()
            return
        }
        unlockTask?.cancel()
        stopWatchingPrompt()
        setPrompt(.touchID)
    }

    private func showUnlocked() {
        setPrompt(.unlocked)
        unlockTask?.cancel()
        unlockTask = Task { [weak self] in
            try? await Task.sleep(for: Self.unlockedDuration)
            guard !Task.isCancelled else { return }
            self?.setPrompt(nil)
        }
    }

    /// A click on the prompt's Cancel button, or Escape.
    private func watchForCancel() {
        let click = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
        }
        let key = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == Self.escapeKeyCode {
                    self?.wasCancelled = true
                }
            }
        }
        eventMonitors = [click, key].compactMap { $0 }
    }

    private func stopWatchingPrompt() {
        promptPID = nil
        cancelButtonFrame = nil
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
    }

    private func clicked(at location: NSPoint) {
        guard let cancelButtonFrame, let mainScreen = NSScreen.screens.first else { return }
        // AppKit measures from the bottom left of the main display.
        let point = CGPoint(x: location.x, y: mainScreen.frame.maxY - location.y)
        if cancelButtonFrame.contains(point) {
            wasCancelled = true
        }
    }

    private func setPrompt(_ newPrompt: Prompt?) {
        guard newPrompt != prompt else { return }
        prompt = newPrompt
        onChange?(newPrompt)
    }

    /// The process with a prompt on screen. Its window's owner name and
    /// bounds are readable without Screen Recording access.
    private static func promptWindowOwner() -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }

        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String, agentNames.contains(owner),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  // coreautha keeps running between prompts; skip anything
                  // too small to be one.
                  bounds.width >= 200, bounds.height >= 100
            else { continue }
            return pid
        }
        return nil
    }

    /// Where the prompt's Cancel button is, through Accessibility.
    private static func cancelButtonFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        // Never hold up the island waiting on a busy agent.
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows: [AXUIElement] = app.attribute(kAXWindowsAttribute) ?? []
        for window in windows {
            if let cancel: AXUIElement = window.attribute(kAXCancelButtonAttribute), let frame = cancel.frame {
                return frame
            }
        }
        return nil
    }
}

private extension AXUIElement {
    func attribute<Value>(_ name: String) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }

    var frame: CGRect? {
        guard let position: AXValue = attribute(kAXPositionAttribute),
              let size: AXValue = attribute(kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

#if DEBUG
extension SignInMonitor {
    /// A prompt that stays as given, for SwiftUI previews.
    static func preview(_ prompt: Prompt) -> SignInMonitor {
        let monitor = SignInMonitor()
        monitor.prompt = prompt
        return monitor
    }

    /// Touch ID that unlocks, played through on a loop for SwiftUI previews.
    static func demo() -> SignInMonitor {
        let monitor = SignInMonitor()
        monitor.prompt = .touchID
        Task { [weak monitor] in
            while !Task.isCancelled {
                guard let monitor else { return }
                do {
                    try await monitor.playDemo()
                } catch {
                    return
                }
            }
        }
        return monitor
    }

    private func playDemo() async throws {
        prompt = .touchID
        try await Task.sleep(for: .seconds(3))
        prompt = .unlocked
        try await Task.sleep(for: .seconds(2.2))
    }
}
#endif
