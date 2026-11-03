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
    /// Accent derived from the artwork, lifted so it reads on black.
    private(set) var tint: Color = .white
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
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
        guard track?.bundleIdentifier == MusicScripting.bundleIdentifier, let id = track?.id else { return }
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
        controller.togglePlayPause()
    }

    func nextTrack() {
        controller.nextTrack()
    }

    func previousTrack() {
        controller.previousTrack()
    }

    func seek(to time: TimeInterval) {
        reanchor(at: time)
        controller.setTime(seconds: time)
    }

    /// Asks the playing app whether the current track is saved.
    func refreshFavorite() async {
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
        Task {
            let accepted = await music.setFavorited(target)
            if !accepted, track?.id == id {
                isFavorite = !target
            }
        }
    }

    // MARK: - Updates

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
            bundleIdentifier: payload.bundleIdentifier,
            isExplicit: payload.isExplicit ?? false
        )
        let isNewTrack = track?.id != next.id

        track = next
        setPlaying(payload.isPlaying ?? false)
        duration = (payload.durationMicros ?? 0) / 1_000_000
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

    private func clearArtwork() {
        artworkTask?.cancel()
        artworkKey = nil
        artwork = nil
        tint = .white
    }
}
