import SwiftUI

/// Artwork in the left wing; in the right, a level meter, the AirPlay
/// device or headphones audio is playing on, or a pause glyph.
///
/// The artwork is inset by the same amount from the top, side and bottom of
/// the pill, and the right-hand glyph sits in a matching square, so both
/// wings look balanced whatever the notch height.
struct NowPlayingCompactView: View {
    let nowPlaying: NowPlayingModel
    let notchSize: CGSize
    /// The connected AirPlay device's or headphones' icon, shown in place
    /// of the meter.
    let routeSystemImage: String?

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
            trailing(size: artSize)
                .frame(width: artSize, height: artSize)
        }
        .padding(inset)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func trailing(size: CGFloat) -> some View {
        if !nowPlaying.isPlaying {
            Image(systemName: "pause.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.islandSecondary)
        } else if let routeSystemImage {
            AudioRouteIcon(systemName: routeSystemImage, size: size)
        } else {
            AudioBars(isPlaying: true, color: nowPlaying.tint)
        }
    }

    private var accessibilityText: String {
        guard let track = nowPlaying.track else { return "Now Playing" }
        return "Now Playing: \(track.title) by \(track.artist)"
    }
}

/// Full player: route, track details, scrubber and transport controls,
/// set in the iPhone's Now Playing type sizes.
struct NowPlayingExpandedView: View {
    let nowPlaying: NowPlayingModel
    let notchHeight: CGFloat
    let route: AudioRoute?
    let sourceName: String

    var body: some View {
        VStack(spacing: 0) {
            header
            PlaybackProgressView(nowPlaying: nowPlaying)
                .padding(.top, NotchViewModel.expandedHeaderGap)
            controls
                .padding(.top, NotchViewModel.expandedControlsGap)
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
                if let route {
                    RouteLabel(source: sourceName, destination: route.destination)
                }
                TrackTitle(track: nowPlaying.track)
                Text(nowPlaying.track?.artist ?? "")
                    .font(.system(size: 17))
                    .foregroundStyle(.islandSecondary)
                    .lineLimit(1)
                    .frame(height: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            AudioBars(isPlaying: nowPlaying.isPlaying, color: nowPlaying.tint)
        }
        .frame(height: 64)
    }

    /// Transport centred on the island; Apple Music's star, when it applies,
    /// sits at the leading edge without pushing them off centre.
    private var controls: some View {
        ZStack {
            HStack(spacing: 26) {
                IslandIconButton(systemName: "backward.fill", size: 26, label: "Previous track") {
                    nowPlaying.previousTrack()
                }
                IslandIconButton(
                    systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    size: 34,
                    label: nowPlaying.isPlaying ? "Pause" : "Play"
                ) {
                    nowPlaying.togglePlayPause()
                }
                IslandIconButton(systemName: "forward.fill", size: 26, label: "Next track") {
                    nowPlaying.nextTrack()
                }
            }

            if nowPlaying.favoriteStyle == .star {
                let isFavorite = nowPlaying.isFavorite ?? false
                IslandIconButton(
                    systemName: isFavorite ? "star.fill" : "star",
                    size: 20,
                    label: isFavorite ? "Unfavorite" : "Favorite",
                    tint: isFavorite ? nowPlaying.tint : .white
                ) {
                    nowPlaying.toggleFavorite()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 44)
    }
}

/// The song name with Apple's explicit badge after it. The badge never
/// truncates; the title does.
struct TrackTitle: View {
    let track: NowPlayingModel.Track?

    var body: some View {
        HStack(spacing: 6) {
            Text(track?.title ?? "")
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            if track?.isExplicit == true {
                Image(systemName: "e.square.fill")
                    .font(.system(size: 15))
                    .accessibilityLabel("Explicit")
            }
        }
        .frame(height: 22)
    }
}

/// "MacBook Pro → HomePod mini", the iPhone's grey line above the title.
private struct RouteLabel: View {
    let source: String
    let destination: String

    var body: some View {
        HStack(spacing: 4) {
            Text(source)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
            Text(destination)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.islandSecondary)
        .lineLimit(1)
        .frame(height: 17)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing from \(source) on \(destination)")
    }
}

/// The device audio is playing on (HomePod, AirPods and so on), drawn the
/// iPhone's way: grey that's lighter at the top, never the artwork tint.
/// Use it wherever the route icon appears, whether Now Playing is the only
/// activity or one of several, so it always looks the same.
struct AudioRouteIcon: View {
    let systemName: String
    /// The square it fills; the glyph is drawn at about 86% of it.
    let size: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.86))
            .foregroundStyle(
                LinearGradient(
                    colors: [Color(white: 0.86), Color(white: 0.54)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .accessibilityHidden(true)
    }
}
