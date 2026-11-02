import SwiftUI

/// Artwork in the left wing, a level meter (or pause glyph) in the right.
///
/// The artwork is inset by the same amount from the top, side and bottom of
/// the pill, and the meter sits in a matching square on the other side, so
/// both wings look balanced whatever the notch height.
struct NowPlayingCompactView: View {
    let nowPlaying: NowPlayingModel
    let notchSize: CGSize

    var body: some View {
        let inset = NotchViewModel.compactInset(notch: notchSize)
        let artSize = notchSize.height - inset * 2

        HStack(spacing: 0) {
            ArtworkView(
                image: nowPlaying.artwork,
                size: artSize,
                cornerRadius: max(NotchViewModel.compactCornerRadius - inset, 4),
                flipID: nowPlaying.track?.id
            )
            Spacer(minLength: 0)
            trailing
                .frame(width: artSize, height: artSize)
        }
        .padding(inset)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        if nowPlaying.isPlaying {
            AudioBars(isPlaying: true, color: nowPlaying.tint)
        } else {
            Image(systemName: "pause.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.islandSecondary)
        }
    }

    private var accessibilityText: String {
        guard let track = nowPlaying.track else { return "Now Playing" }
        return "Now Playing: \(track.title) by \(track.artist)"
    }
}

/// The song name with Apple's explicit badge after it. The badge never
/// truncates; the title does.
struct TrackTitle: View {
    let track: NowPlayingModel.Track?

    var body: some View {
        HStack(spacing: 4) {
            Text(track?.title ?? "")
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .lineLimit(1)
            if track?.isExplicit == true {
                Image(systemName: "e.square.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Explicit")
            }
        }
        .frame(height: 20)
    }
}

/// Full player: track details, scrubber and transport controls.
struct NowPlayingExpandedView: View {
    let nowPlaying: NowPlayingModel
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            header
            PlaybackProgressView(nowPlaying: nowPlaying)
                .padding(.top, 12)
            controls
                .padding(.top, 6)
        }
        // The artwork sits as far below the notch as it is from the side.
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedInset)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
        .task(id: nowPlaying.track?.id) {
            await nowPlaying.refreshFavorite()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(image: nowPlaying.artwork, size: 64, cornerRadius: 12, flipID: nowPlaying.track?.id)
            VStack(alignment: .leading, spacing: 0) {
                TrackTitle(track: nowPlaying.track)
                Text(nowPlaying.track?.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
                    .frame(height: 18)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            AudioBars(isPlaying: nowPlaying.isPlaying, color: nowPlaying.tint)
        }
        .frame(height: 64)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            favoriteButton
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                IslandIconButton(systemName: "backward.fill", size: 21, label: "Previous track") {
                    nowPlaying.previousTrack()
                }
                IslandIconButton(
                    systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    size: 26,
                    label: nowPlaying.isPlaying ? "Pause" : "Play"
                ) {
                    nowPlaying.togglePlayPause()
                }
                IslandIconButton(systemName: "forward.fill", size: 21, label: "Next track") {
                    nowPlaying.nextTrack()
                }
            }
            Spacer(minLength: 0)
            // Reserved for the audio output button, so the transport
            // controls stay centred.
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .frame(height: 44)
    }

    /// Mirrors the playing app: Apple Music's star, or nothing for apps
    /// without a way to save tracks. The empty slot keeps the transport
    /// controls centred.
    @ViewBuilder
    private var favoriteButton: some View {
        switch nowPlaying.favoriteStyle {
        case .star:
            let isFavorite = nowPlaying.isFavorite ?? false
            IslandIconButton(
                systemName: isFavorite ? "star.fill" : "star",
                size: 17,
                label: isFavorite ? "Unfavorite" : "Favorite",
                tint: isFavorite ? nowPlaying.tint : .white
            ) {
                nowPlaying.toggleFavorite()
            }
        case nil:
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }
}
