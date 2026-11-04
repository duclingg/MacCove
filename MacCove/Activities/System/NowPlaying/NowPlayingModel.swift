//
//  NowPlayingModel.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit
import MediaRemoteAdapter
import SwiftUI

/// System-wide Now Playing state, read through MediaRemote.
///
/// Since macOS 15.4 only Apple-signed processes may read MediaRemote, so the
/// adapter runs the framework inside `/usr/bin/perl` and streams updates back
/// as JSON. Playback position is reported as a snapshot (elapsed time at a
/// timestamp) and interpolated locally between updates.
@Observable
final class NowPlayingModel {
    struct Track: Equatable {
        var id: String
        var title: String
        var artist: String
        var album: String
        /// The app that owns the session, such as `com.apple.Music`.
        var bundleIdentifier: String?
        /// Shows the "E" badge. Only as reliable as the app reporting it.
        var isExplicit: Bool
    }

    /// How the playing app lets you save a track, mirroring its own UI.
    enum FavoriteStyle {
        /// Apple Music's Favorite.
        case star
    }

    private(set) var track: Track?
    private(set) var artwork: NSImage?
    /// The playing app's icon, shown in place of artwork when there's none,
    /// as on the iPhone.
    private(set) var appIcon: NSImage?
    /// Accent derived from the artwork, lifted so it reads on black.
    private(set) var tint: Color = .white
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    /// Whether the app reports a playhead at all. Some web players,
    /// Netflix's among them, report neither a length nor a position.
    private(set) var reportsPosition = false
    /// `nil` until the playing app has been asked.
    private(set) var isFavorite: Bool?

    private var elapsedAnchor: TimeInterval = 0
    private var anchorDate = Date()
    private var playbackRate: Double = 1
    private var artworkKey: Int?
    /// How far the player's own playhead is ahead of MediaRemote's snapshot.
    /// Music's snapshot trails what its window shows by around a second, so
    /// this is measured from Music directly. It's 0 for other apps.
    private var positionCorrection: TimeInterval = 0

    /// Lets the island dismiss itself on pause, like the iPhone.
    @ObservationIgnored var onPlayingChange: ((Bool) -> Void)?
    @ObservationIgnored private let controller = MediaController()
    @ObservationIgnored private let music: MusicScripting
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    #if DEBUG
    /// A preview model plays along by itself instead of driving the player.
    @ObservationIgnored private var isPreview = false
    #endif

    init(music: MusicScripting) {
        self.music = music
    }

    var hasMedia: Bool { track != nil }

    var isAppleMusicPlaying: Bool {
        isPlaying && track?.bundleIdentifier == MusicScripting.bundleIdentifier
    }

    /// Apps without a way to save tracks get no button at all.
    var favoriteStyle: FavoriteStyle? {
        track?.bundleIdentifier == MusicScripting.bundleIdentifier ? .star : nil
    }

    /// Podcast and audiobook apps, which get 15-second skips instead of
    /// previous and next track, as on the iPhone.
    private static let spokenAudioApps: Set<String> = [
        "com.apple.podcasts",
        "com.apple.iBooksX",
        "au.com.shiftyjelly.podcasts",
        "fm.overcast.overcast",
    ]

    var isSpokenAudio: Bool {
        guard let bundleIdentifier = track?.bundleIdentifier else { return false }
        return Self.spokenAudioApps.contains(bundleIdentifier)
    }

    /// Radio and live video report a position but no length.
    var isLive: Bool {
        hasMedia && duration <= 0 && reportsPosition
    }

    /// Anything to show on the progress bar: a length, or at least a
    /// position.
    var hasTimeline: Bool {
        duration > 0 || reportsPosition
    }

    /// "Artist • Album", leaving out whichever the app doesn't report.
    var subtitle: String {
        guard let track else { return "" }
        return [track.artist, track.album]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    func start() {
        controller.onTrackInfoReceived = { [weak self] info in
            MainActor.assumeIsolated { self?.apply(info) }
        }
        controller.onListenerTerminated = { [weak self] in
            MainActor.assumeIsolated { self?.restartListening() }
        }
        controller.startListening()
    }

    func elapsed(at date: Date) -> TimeInterval {
        let value = snapshotElapsed(at: date) + positionCorrection
        return duration > 0 ? min(max(value, 0), duration) : max(value, 0)
    }

    /// Re-measures `positionCorrection` against Music's playhead. Called while
    /// the player is on screen; does nothing for other apps.
    func syncPositionWithPlayer() async {
        guard drivesPlayer, track?.bundleIdentifier == MusicScripting.bundleIdentifier, let id = track?.id else { return }
        let sent = Date()
        guard let position = await music.playerPosition() else { return }
        let received = Date()
        guard track?.id == id else { return }
        // Assume Music read its playhead halfway through the round trip.
        let readAt = sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
        let correction = position - snapshotElapsed(at: readAt)
        // Anything larger is a seek or track change racing the snapshot, not lag.
        positionCorrection = abs(correction) <= 3 ? correction : 0
    }

    // MARK: - Controls

    func togglePlayPause() {
        reanchor(at: elapsed(at: Date()))
        setPlaying(!isPlaying)
        guard drivesPlayer else { return }
        controller.togglePlayPause()
    }

    func nextTrack() {
        guard drivesPlayer else { return }
        controller.nextTrack()
    }

    func previousTrack() {
        guard drivesPlayer else { return }
        controller.previousTrack()
    }

    func seek(to time: TimeInterval) {
        reanchor(at: time)
        guard drivesPlayer else { return }
        controller.setTime(seconds: time)
    }

    func skipBackward() {
        reanchor(at: max(elapsed(at: Date()) - 15, 0))
        guard drivesPlayer else { return }
        controller.goBackFifteenSeconds()
    }

    func skipForward() {
        let ahead = elapsed(at: Date()) + 15
        reanchor(at: duration > 0 ? min(ahead, duration) : ahead)
        guard drivesPlayer else { return }
        controller.skipFifteenSeconds()
    }

    /// Brings the app that's playing to the front, like tapping the
    /// iPhone's player. For a browser that's the browser, not the tab.
    func openSourceApp() {
        guard drivesPlayer, let bundleIdentifier = track?.bundleIdentifier else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    /// Asks the playing app whether the current track is saved.
    func refreshFavorite() async {
        guard drivesPlayer else { return }
        guard favoriteStyle == .star, let id = track?.id else {
            isFavorite = nil
            return
        }
        let favorited = await music.isFavorited()
        guard track?.id == id else { return }
        isFavorite = favorited
    }

    func toggleFavorite() {
        guard favoriteStyle == .star, let id = track?.id else { return }
        let target = !(isFavorite ?? false)
        isFavorite = target
        guard drivesPlayer else { return }
        Task {
            let accepted = await music.setFavorited(target)
            if !accepted, track?.id == id {
                isFavorite = !target
            }
        }
    }

    // MARK: - Updates

    /// False for a preview model, which only changes its own state.
    private var drivesPlayer: Bool {
        #if DEBUG
        !isPreview
        #else
        true
        #endif
    }

    private func restartListening() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.controller.startListening()
        }
    }

    private func reanchor(at time: TimeInterval) {
        elapsedAnchor = time - positionCorrection
        anchorDate = Date()
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        onPlayingChange?(playing)
    }

    private func snapshotElapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsedAnchor }
        return elapsedAnchor + date.timeIntervalSince(anchorDate) * playbackRate
    }

    private func apply(_ info: TrackInfo?) {
        guard let payload = info?.payload, let title = payload.title, !title.isEmpty else {
            track = nil
            appIcon = nil
            clearArtwork()
            setPlaying(false)
            isFavorite = nil
            return
        }

        let next = Track(
            id: payload.uniqueIdentifier,
            title: title,
            artist: payload.artist ?? "",
            album: payload.album ?? "",
            bundleIdentifier: payload.bundleIdentifier.map(Self.owningApp),
            isExplicit: payload.isExplicit ?? false
        )
        let isNewTrack = track?.id != next.id
        if next.bundleIdentifier != track?.bundleIdentifier {
            appIcon = next.bundleIdentifier.flatMap(Self.icon(forApp:))
        }

        track = next
        setPlaying(payload.isPlaying ?? false)
        duration = (payload.durationMicros ?? 0) / 1_000_000
        reportsPosition = payload.elapsedTimeMicros != nil
        if let rate = payload.playbackRate, rate > 0 {
            playbackRate = rate
        } else {
            playbackRate = 1
        }
        if let elapsedMicros = payload.elapsedTimeMicros {
            elapsedAnchor = elapsedMicros / 1_000_000
            anchorDate = payload.timestampEpochMicros.map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        }

        if isNewTrack {
            isFavorite = nil
            positionCorrection = 0
        }
        updateArtwork(payload, isNewTrack: isNewTrack)
    }

    private func updateArtwork(_ payload: TrackInfo.Payload, isNewTrack: Bool) {
        guard let base64 = payload.artworkDataBase64, !base64.isEmpty else {
            // Artwork often arrives a moment after the title; keep the old
            // image only while it still belongs to the current track.
            if isNewTrack {
                clearArtwork()
            }
            return
        }
        let key = base64.hashValue
        guard key != artworkKey else { return }
        artworkKey = key
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let processed = await ProcessedArtwork.make(fromBase64: base64),
                  !Task.isCancelled,
                  let self,
                  self.artworkKey == key else { return }
            self.artwork = NSImage(
                cgImage: processed.image,
                size: NSSize(width: processed.image.width, height: processed.image.height)
            )
            self.tint = Color(nsColor: processed.tint)
        }
    }

    /// Media helpers report sessions on their app's behalf. Safari's media
    /// plays in WebKit's GPU process, which can't be opened and has no icon
    /// of its own.
    private static let helperOwners = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
        "com.apple.WebKit.WebContent": "com.apple.Safari",
    ]

    private static func owningApp(_ bundleIdentifier: String) -> String {
        helperOwners[bundleIdentifier] ?? bundleIdentifier
    }

    private static func icon(forApp bundleIdentifier: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
    }

    private func clearArtwork() {
        artworkTask?.cancel()
        artworkKey = nil
        artwork = nil
        tint = .white
    }
}

#if DEBUG
extension NowPlayingModel {
    /// A track that plays along without any player, for SwiftUI previews.
    /// Play, pause, seek, skip and Favorite all work on its own state.
    static func preview(
        title: String,
        artist: String,
        album: String = "",
        app bundleIdentifier: String = "com.spotify.client",
        isExplicit: Bool = false,
        isPlaying: Bool = true,
        /// `nil` for an app that reports no playhead.
        elapsed: TimeInterval? = 84,
        duration: TimeInterval = 228,
        isFavorite: Bool? = nil,
        artwork: NSImage? = nil,
        tint: Color = .white
    ) -> NowPlayingModel {
        let model = NowPlayingModel(music: MusicScripting())
        model.isPreview = true
        model.track = Track(
            id: "\(bundleIdentifier)/\(title)",
            title: title,
            artist: artist,
            album: album,
            bundleIdentifier: bundleIdentifier,
            isExplicit: isExplicit
        )
        model.isPlaying = isPlaying
        model.duration = duration
        model.reportsPosition = elapsed != nil
        model.elapsedAnchor = elapsed ?? 0
        model.anchorDate = Date()
        model.isFavorite = isFavorite
        model.artwork = artwork
        model.appIcon = icon(forApp: bundleIdentifier)
        model.tint = tint
        return model
    }
}
#endif
