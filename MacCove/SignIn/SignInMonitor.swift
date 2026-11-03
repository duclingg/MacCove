import Foundation

/// The lock screen, as the island shows it: Touch ID while locked, then
/// the unlock. Unlocking, by Touch ID or the password, plays the unlock.
///
/// Touch ID prompts from apps, `sudo` and System Settings aren't shown;
/// the island only signs you in at the lock screen.
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

    @ObservationIgnored var onChange: ((Prompt?) -> Void)?

    private static let unlockedDuration: Duration = .seconds(1.6)

    @ObservationIgnored private var unlockTask: Task<Void, Never>?
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
    }

    /// Unlocking can only mean the password or Touch ID was accepted.
    private func screenLockChanged(locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        unlockTask?.cancel()
        guard locked else {
            showUnlocked()
            return
        }
        setPrompt(.touchID)
    }

    private func showUnlocked() {
        setPrompt(.unlocked)
        unlockTask = Task { [weak self] in
            try? await Task.sleep(for: Self.unlockedDuration)
            guard !Task.isCancelled else { return }
            self?.setPrompt(nil)
        }
    }

    private func setPrompt(_ newPrompt: Prompt?) {
        guard newPrompt != prompt else { return }
        prompt = newPrompt
        onChange?(newPrompt)
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
