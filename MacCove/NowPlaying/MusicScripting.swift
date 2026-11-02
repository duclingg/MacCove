import AppKit
import ScriptingBridge

/// Talks to Apple Music over Apple Events: the per-track Favorite (star)
/// and the player's exact playhead position.
///
/// Apple Events are synchronous round trips to Music, so they run on this
/// actor rather than the main thread. The first call triggers macOS's
/// Automation prompt ("MacCove wants to control Music").
actor MusicScripting {
    static let bundleIdentifier = "com.apple.Music"

    private var app: SBApplication?

    /// `nil` when Music isn't running, has no current track, or the user
    /// declined Automation access.
    func isFavorited() -> Bool? {
        guard let track = currentTrack() else { return nil }
        return (track.value(forKey: "favorited") as? NSNumber)?.boolValue
    }

    /// Returns whether Music accepted the change.
    func setFavorited(_ favorited: Bool) -> Bool {
        guard let track = currentTrack() else { return false }
        track.setValue(favorited, forKey: "favorited")
        return isFavorited() == favorited
    }

    /// Seconds into the current track, read from Music's player itself.
    func playerPosition() -> Double? {
        guard let app = runningApp() else { return nil }
        return (app.value(forKey: "playerPosition") as? NSNumber)?.doubleValue
    }

    private func currentTrack() -> SBObject? {
        runningApp()?.value(forKey: "currentTrack") as? SBObject
    }

    private func runningApp() -> SBApplication? {
        // Never launch Music just to ask it something.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty else {
            return nil
        }
        if app == nil {
            app = SBApplication(bundleIdentifier: Self.bundleIdentifier)
        }
        return app
    }
}
