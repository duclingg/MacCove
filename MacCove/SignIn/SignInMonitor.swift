import AppKit
import ApplicationServices
import OSLog

/// The system's Touch ID and password prompts, as the island shows them:
/// waiting for a finger, the password going in a dot at a time, and
/// unlocked.
///
/// macOS doesn't announce these prompts, so their windows are watched for.
/// SecurityAgent draws the ones for admin rights and System Settings, and
/// coreautha the LocalAuthentication ones that apps and `sudo` ask for.
/// Seeing a prompt needs no permission. With Accessibility access it can
/// also be read: whether it's asking for the password, how many characters
/// are in the field (never what they are), and whether it was cancelled,
/// which is what tells unlocking apart from giving up. Without it the
/// island shows Touch ID and leaves quietly with the prompt.
///
/// The lock screen counts too: locking shows Touch ID, and unlocking, by
/// either method, plays the unlock. Its password field belongs to
/// loginwindow, which is read the same way when it allows it.
///
/// Nothing tells other apps when a finger is on the sensor, so the
/// fingerprint can't react to the touch itself, only to the result.
@Observable
final class SignInMonitor {
    enum Prompt: Equatable {
        case touchID
        /// Characters in the password field.
        case password(length: Int)
        case unlocked
    }

    private(set) var prompt: Prompt?
    /// Goes up each time a typed password is turned away, to shake the dots.
    private(set) var rejections = 0
    private(set) var hasAccessibilityAccess = AXIsProcessTrusted()
    private(set) var isScreenLocked = false

    @ObservationIgnored var onChange: ((Prompt?) -> Void)?

    /// The processes that draw the prompts, by the name their windows give.
    private static let agentNames: Set<String> = ["SecurityAgent", "coreautha"]
    private static let loginWindowBundleID = "com.apple.loginwindow"
    private static let log = Logger(subsystem: "com.justinhoang.MacCove", category: "SignIn")
    /// Twice a second while nothing is up, and ten times a second while a
    /// prompt is, so each key shows as it's typed.
    private static let idleInterval: Duration = .milliseconds(500)
    private static let activeInterval: Duration = .milliseconds(100)
    private static let unlockedDuration: Duration = .seconds(1.6)
    /// A password still in the field this recently when the prompt closes
    /// was submitted; the field can clear a moment before the window goes.
    private static let submitWindow: Duration = .seconds(1)
    private static let escapeKeyCode: UInt16 = 53

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var unlockTask: Task<Void, Never>?
    @ObservationIgnored private var eventMonitors: [Any] = []
    /// The agent showing the open prompt, `nil` while there isn't one.
    @ObservationIgnored private var promptPID: pid_t?
    /// In Accessibility's coordinates: from the top left of the main display.
    @ObservationIgnored private var cancelButtonFrame: CGRect?
    @ObservationIgnored private var wasCancelled = false
    @ObservationIgnored private var lastTypedAt: ContinuousClock.Instant?
    /// Why a password field couldn't be read is logged once per prompt.
    @ObservationIgnored private var hasLoggedReading = false
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
        if isScreenLocked {
            // Quickly only once typing has started: the Mac can stay locked
            // all night.
            return readLockScreen() ? Self.activeInterval : Self.idleInterval
        }
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
            lastTypedAt = nil
            hasLoggedReading = false
            if hasAccessibilityAccess {
                watchForCancel()
            }
        }
        promptPID = pid

        let reading = hasAccessibilityAccess ? PromptReading(pid: pid) : nil
        cancelButtonFrame = reading?.cancelButtonFrame
        if let reading {
            logIfUnreadable(reading, of: "the prompt")
        }

        if let length = reading?.passwordLength {
            showTyped(length)
        } else if case .password? = prompt {
            // Stays on the password once it's chosen, even if a reading
            // misses the field.
        } else {
            setPrompt(.touchID)
        }
    }

    private func promptClosed() {
        guard promptPID != nil else { return }
        promptPID = nil
        cancelButtonFrame = nil
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []

        let unlocked: Bool
        switch prompt {
        case .touchID?:
            unlocked = hasAccessibilityAccess && !wasCancelled
        case .password?:
            let submitted = lastTypedAt.map { ContinuousClock.Instant.now - $0 < Self.submitWindow } ?? false
            unlocked = submitted && !wasCancelled
        case .unlocked?, nil:
            unlocked = false
        }

        if unlocked {
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
        promptPID = nil
        cancelButtonFrame = nil
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
        lastTypedAt = nil
        hasLoggedReading = false
        // Reported even if a Touch ID prompt was already up, so the island
        // closes for the lock screen.
        prompt = .touchID
        onChange?(.touchID)
    }

    /// Whether the password is being typed on the lock screen. Its field
    /// can sit there empty under Touch ID, so the island moves to the
    /// password only with the first character.
    private func readLockScreen() -> Bool {
        guard hasAccessibilityAccess,
              let loginWindow = NSRunningApplication.runningApplications(withBundleIdentifier: Self.loginWindowBundleID).first
        else { return false }
        let reading = PromptReading(pid: loginWindow.processIdentifier)
        logIfUnreadable(reading, of: "the lock screen")
        guard let length = reading.passwordLength else { return false }
        let isTyping = if case .password? = prompt { true } else { length > 0 }
        if isTyping {
            showTyped(length)
        }
        return isTyping
    }

    /// Says once per prompt why no password field turned up, to tell
    /// macOS refusing Accessibility apart from the field not being found.
    /// Shows in Console with the subsystem com.justinhoang.MacCove.
    private func logIfUnreadable(_ reading: PromptReading, of source: String) {
        guard !hasLoggedReading, reading.passwordLength == nil else { return }
        hasLoggedReading = true
        if let error = reading.windowsError {
            Self.log.notice("Couldn't read \(source, privacy: .public)'s windows: AXError \(error.rawValue, privacy: .public)")
        } else {
            Self.log.notice("No password field in \(source, privacy: .public)'s \(reading.windowCount, privacy: .public) windows yet")
        }
    }

    private func showTyped(_ length: Int) {
        if length > 0 {
            lastTypedAt = .now
        }
        // Cleared all at once, with the prompt still up: macOS turned the
        // password away.
        if case .password(let typed)? = prompt, typed >= 2, length == 0 {
            rejections += 1
        }
        setPrompt(.password(length: length))
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

    /// A click on the prompt's Cancel button, or Escape. Escape can't be
    /// seen while the password field has focus, since macOS keeps typing
    /// there from every other app; a prompt that closes with the field empty
    /// counts as cancelled instead.
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
}

/// What a prompt's window says through Accessibility.
private struct PromptReading {
    /// Characters in the password field, `nil` while it isn't showing:
    /// Touch ID prompts keep it hidden until you choose the password.
    var passwordLength: Int?
    var cancelButtonFrame: CGRect?
    /// Why the windows couldn't be listed, if they couldn't.
    var windowsError: AXError?
    var windowCount = 0

    init(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        // Never hold up the island waiting on a busy agent.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        windowsError = result == .success ? nil : result
        let windows = value as? [AXUIElement] ?? []
        windowCount = windows.count
        for window in windows {
            if passwordLength == nil, let field = window.firstDescendant(depth: 8, where: \.isShownSecureTextField) {
                passwordLength = field.characterCount
            }
            if cancelButtonFrame == nil, let cancel: AXUIElement = window.attribute(kAXCancelButtonAttribute) {
                cancelButtonFrame = cancel.frame
            }
        }
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

    var isShownSecureTextField: Bool {
        guard attribute(kAXSubroleAttribute) as String? == kAXSecureTextFieldSubrole else { return false }
        return (frame?.height ?? 0) > 1
    }

    /// Secure fields report their length, or a bullet per character, but
    /// never the characters.
    var characterCount: Int {
        let count: Int = attribute(kAXNumberOfCharactersAttribute) ?? 0
        let bullets = (attribute(kAXValueAttribute) as String?)?.count ?? 0
        return max(count, bullets)
    }

    func firstDescendant(depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth > 0 else { return nil }
        let children: [AXUIElement] = attribute(kAXChildrenAttribute) ?? []
        for child in children {
            if matches(child) {
                return child
            }
            if let found = child.firstDescendant(depth: depth - 1, where: matches) {
                return found
            }
        }
        return nil
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

    /// A prompt played through on a loop, for SwiftUI previews: Touch ID
    /// that unlocks, or the password typed wrong once and then right.
    static func demo(typingPassword: Bool) -> SignInMonitor {
        let monitor = SignInMonitor()
        monitor.prompt = .touchID
        Task { [weak monitor] in
            while !Task.isCancelled {
                guard let monitor else { return }
                do {
                    try await monitor.playDemo(typingPassword: typingPassword)
                } catch {
                    return
                }
            }
        }
        return monitor
    }

    private func playDemo(typingPassword: Bool) async throws {
        prompt = .touchID
        try await Task.sleep(for: .seconds(3))
        if typingPassword {
            prompt = .password(length: 0)
            try await Task.sleep(for: .seconds(0.8))
            try await type(5)
            try await Task.sleep(for: .seconds(0.4))
            prompt = .password(length: 0)
            rejections += 1
            try await Task.sleep(for: .seconds(1))
            try await type(8)
            try await Task.sleep(for: .seconds(0.4))
        }
        prompt = .unlocked
        try await Task.sleep(for: .seconds(2.2))
    }

    private func type(_ count: Int) async throws {
        for length in 1...count {
            prompt = .password(length: length)
            try await Task.sleep(for: .milliseconds(170))
        }
    }
}
#endif
