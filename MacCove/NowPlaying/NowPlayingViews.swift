import SwiftUI

/// Artwork in the left wing; in the right, a level meter, the AirPlay
/// device or headphones audio is playing on, or a pause glyph, centred in a
/// square that mirrors the artwork. Sized and placed like the iPhone's
/// (see `CompactLayout`).
struct NowPlayingCompactView: View {
    let nowPlaying: NowPlayingModel
    let notchSize: CGSize
    /// The connected AirPlay device's or headphones' icon, shown in place
    /// of the meter.
    let routeSystemImage: String?

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let artSize = layout.artSize

        HStack(spacing: 0) {
            ArtworkView(
                image: nowPlaying.artwork,
                size: artSize,
                // Like the iPhone's: rounded by about a sixth of its size.
                cornerRadius: (artSize * 0.18).rounded(),
                flipID: nowPlaying.track?.id,
                fallbackIcon: nowPlaying.appIcon
            )
            Spacer(minLength: 0)
            trailing(size: artSize)
                .frame(width: artSize, height: artSize)
        }
        .padding(.horizontal, layout.sideInset)
        .padding(.vertical, layout.verticalInset)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nowPlayingDescription(nowPlaying))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func trailing(size: CGFloat) -> some View {
        if !nowPlaying.isPlaying {
            Image(systemName: "pause.fill")
                .font(.system(size: (size * 0.6).rounded(), weight: .medium))
                .foregroundStyle(.islandSecondary)
        } else if let routeSystemImage {
            // About 18pt beside 23pt artwork, as on the iPhone.
            AudioRouteIcon(systemName: routeSystemImage, pointSize: (size * 0.78).rounded())
        } else {
            AudioBars(isPlaying: true, color: nowPlaying.tint)
        }
    }
}

/// Now Playing in a bubble beside another activity: just the artwork, as
/// the pill draws it.
struct NowPlayingMinimalView: View {
    let nowPlaying: NowPlayingModel
    let notchSize: CGSize

    var body: some View {
        let artSize = CompactLayout(notch: notchSize).artSize

        ArtworkView(
            image: nowPlaying.artwork,
            size: artSize,
            cornerRadius: (artSize * 0.18).rounded(),
            flipID: nowPlaying.track?.id,
            fallbackIcon: nowPlaying.appIcon
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nowPlayingDescription(nowPlaying))
        .accessibilityAddTraits(.isButton)
    }
}

private func nowPlayingDescription(_ nowPlaying: NowPlayingModel) -> String {
    guard let track = nowPlaying.track else { return "Now Playing" }
    return "Now Playing: \(track.title) by \(track.artist)"
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
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
        .task(id: nowPlaying.track?.id) {
            await nowPlaying.refreshFavorite()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            // Clicking the artwork or the text opens the app that's playing,
            // like tapping the iPhone's player.
            Button {
                nowPlaying.openSourceApp()
            } label: {
                HStack(spacing: 14) {
                    ArtworkView(
                        image: nowPlaying.artwork,
                        size: 64,
                        cornerRadius: 8,
                        flipID: nowPlaying.track?.id,
                        fallbackIcon: nowPlaying.appIcon
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        if let route {
                            RouteLabel(source: sourceName, destination: route.destination)
                        }
                        TrackTitle(track: nowPlaying.track)
                        MarqueeText(text: nowPlaying.subtitle, font: .system(size: 17))
                            .foregroundStyle(.islandSecondary)
                            .frame(height: 22)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the app that's playing")
            AudioBars(isPlaying: nowPlaying.isPlaying, color: nowPlaying.tint)
        }
        .frame(height: 64)
    }

    /// Transport centred on the island: previous and next track, or
    /// 15-second skips for podcasts and audiobooks. Apple Music's star, when
    /// it applies, sits at the leading edge, and the device audio is playing
    /// on at the trailing edge, neither pushing the transport off centre.
    private var controls: some View {
        ZStack {
            HStack(spacing: 26) {
                if nowPlaying.isSpokenAudio {
                    IslandIconButton(systemName: "gobackward.15", size: 24, label: "Back 15 seconds") {
                        nowPlaying.skipBackward()
                    }
                } else {
                    IslandIconButton(systemName: "backward.fill", size: 26, label: "Previous track") {
                        nowPlaying.previousTrack()
                    }
                }
                IslandIconButton(
                    systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    size: 34,
                    label: nowPlaying.isPlaying ? "Pause" : "Play"
                ) {
                    nowPlaying.togglePlayPause()
                }
                if nowPlaying.isSpokenAudio {
                    IslandIconButton(systemName: "goforward.15", size: 24, label: "Forward 15 seconds") {
                        nowPlaying.skipForward()
                    }
                } else {
                    IslandIconButton(systemName: "forward.fill", size: 26, label: "Next track") {
                        nowPlaying.nextTrack()
                    }
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

            // Only while audio is on an external device we can name; an
            // indicator, not a button.
            if let route, route.isIdentified {
                AudioRouteIcon(systemName: route.systemImage, pointSize: 21)
                    .frame(width: 44, height: 44)
                    .accessibilityElement()
                    .accessibilityLabel("Playing on \(route.destination)")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 44)
    }
}

/// The song name with Apple's explicit badge after it. A long title
/// scrolls; the badge stays put.
struct TrackTitle: View {
    let track: NowPlayingModel.Track?

    var body: some View {
        HStack(spacing: 6) {
            MarqueeText(text: track?.title ?? "", font: .system(size: 17, weight: .semibold))
            if track?.isExplicit == true {
                Image(systemName: "e.square.fill")
                    .font(.system(size: 15))
                    .fixedSize()
                    .accessibilityLabel("Explicit")
            }
        }
        .frame(height: 22)
    }
}

/// "MacBook Pro → HomePod mini", the iPhone's caption above the title:
/// smaller and dimmer than the artist line, so it reads as context.
private struct RouteLabel: View {
    let source: String
    let destination: String

    var body: some View {
        HStack(spacing: 3) {
            Text(source)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
            Text(destination)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.islandTertiary)
        .lineLimit(1)
        .frame(height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing from \(source) on \(destination)")
    }
}

/// The device audio is playing on (HomePod, AirPods and so on), drawn the
/// iPhone's way: the symbol's main layer (a HomePod's top, the AirPods
/// themselves) in near-white and the rest in dark grey, never the artwork
/// tint. Use it wherever the route icon appears, whether Now Playing is the
/// only activity or one of several, so it always looks the same.
struct AudioRouteIcon: View {
    let systemName: String
    let pointSize: CGFloat

    private static let primary = Color(white: 0.88)
    private static let secondary = Color(white: 0.3)

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Self.primary, Self.secondary, Self.secondary)
            .font(.system(size: pointSize))
            .accessibilityHidden(true)
    }
}
