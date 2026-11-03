import AppKit
import ScriptingBridge

/// One of Music's AirPlay devices. `kind` is Music's four-character device
/// kind code ('kAPH' for HomePod and so on).
nonisolated struct MusicAirPlayDevice: Sendable, Equatable {
    static let computer: UInt32 = 0x6B41_5043 // 'kAPC', this Mac
    static let homePod: UInt32 = 0x6B41_5048 // 'kAPH'
    static let appleTV: UInt32 = 0x6B41_5054 // 'kAPT'
    static let tv: UInt32 = 0x6B41_5056 // 'kAPV'

    let name: String
    let kind: UInt32
}

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

    /// The devices Music is playing to through its own AirPlay picker,
    /// including the Mac itself (kind "computer") when it's one of them.
    func currentAirPlayDevices() -> [MusicAirPlayDevice]? {
        guard let app = runningApp(),
              let devices = app.value(forKey: "currentAirPlayDevices") as? [SBObject] else { return nil }
        return devices.compactMap { device in
            guard let name = device.value(forKey: "name") as? String else { return nil }
            let kind = (device.value(forKey: "kind") as? NSNumber)?.uint32Value ?? 0
            return MusicAirPlayDevice(name: name, kind: kind)
        }
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
