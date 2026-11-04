//
//  NowPlayingPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

// MARK: - Sample tracks

/// The canvas's three made-up albums, drawn as artwork with the tint the
/// island would pick from them.
private enum SampleAlbum {
    case slowOrbit
    case paperLanterns
    case staticBloom

    var tint: Color {
        switch self {
        case .slowOrbit: Color(red: 246 / 255, green: 178 / 255, blue: 107 / 255)
        case .paperLanterns: Color(red: 1, green: 143 / 255, blue: 117 / 255)
        case .staticBloom: Color(red: 238 / 255, green: 130 / 255, blue: 176 / 255)
        }
    }

    var image: NSImage? {
        let renderer = ImageRenderer(content: cover.frame(width: 300, height: 300))
        renderer.scale = 2
        return renderer.nsImage
    }

    @ViewBuilder
    private var cover: some View {
        switch self {
        case .slowOrbit:
            ZStack {
                VStack(spacing: 0) {
                    Color(red: 28 / 255, green: 37 / 255, blue: 65 / 255).frame(height: 198)
                    Color(red: 11 / 255, green: 19 / 255, blue: 43 / 255)
                }
                Circle().fill(tint).frame(width: 150).position(x: 204, y: 120)
            }
        case .paperLanterns:
            ZStack {
                LinearGradient(
                    colors: [Color(red: 15 / 255, green: 76 / 255, blue: 74 / 255), Color(red: 10 / 255, green: 50 / 255, blue: 52 / 255)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle().fill(tint).frame(width: 120).position(x: 102, y: 102)
                Circle().fill(Color(red: 1, green: 216 / 255, blue: 168 / 255)).frame(width: 78).position(x: 210, y: 198)
            }
        case .staticBloom:
            ZStack {
                Color(red: 43 / 255, green: 27 / 255, blue: 46 / 255)
                Circle().fill(Color(red: 244 / 255, green: 199 / 255, blue: 218 / 255)).frame(width: 216)
                Circle().fill(Color(red: 224 / 255, green: 85 / 255, blue: 154 / 255)).frame(width: 108)
            }
        }
    }
}

private func track(
    _ album: SampleAlbum?,
    title: String = "Slow Orbit",
    artist: String = "Marlow Vane",
    albumName: String = "Night Shift",
    app: String = "com.spotify.client",
    isExplicit: Bool = false,
    isPlaying: Bool = true,
    elapsed: TimeInterval? = 84,
    duration: TimeInterval = 228,
    isFavorite: Bool? = nil
) -> NowPlayingModel {
    .preview(
        title: title,
        artist: artist,
        album: albumName,
        app: app,
        isExplicit: isExplicit,
        isPlaying: isPlaying,
        elapsed: elapsed,
        duration: duration,
        isFavorite: isFavorite,
        artwork: album?.image,
        tint: album?.tint ?? .white
    )
}

private let homePod = AudioRoute(destination: "Living Room", device: .homePod)
private let airPodsPro = AudioRoute(destination: "Justin's AirPods Pro", device: .airPodsPro)

// MARK: - Island frames

private func compact(_ nowPlaying: NowPlayingModel, route: AudioRoute? = nil) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        NowPlayingCompactView(nowPlaying: nowPlaying, notchSize: notch, routeSystemImage: route?.systemImage)
    }
}

private func expanded(_ nowPlaying: NowPlayingModel, route: AudioRoute? = nil) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + NotchViewModel.expandedBodyHeight),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        NowPlayingExpandedView(nowPlaying: nowPlaying, notchHeight: notch.height, route: route, sourceName: "MacBook Pro")
    }
}

// MARK: - Compact

#Preview("Compact · Playing") {
    compact(track(.slowOrbit))
}

#Preview("Compact · Paused") {
    compact(track(.paperLanterns, isPlaying: false))
}

#Preview("Compact · On a HomePod") {
    compact(track(.staticBloom), route: homePod)
}

#Preview("Compact · On AirPods Pro") {
    compact(track(.slowOrbit), route: airPodsPro)
}

// MARK: - Expanded (the controls work: play, pause, seek, Favorite)

#Preview("Expanded · Playing") {
    expanded(track(.slowOrbit))
}

#Preview("Expanded · Apple Music on a HomePod") {
    expanded(
        track(
            .staticBloom,
            title: "Static Bloom",
            artist: "The Halden Set",
            albumName: "Static Bloom",
            app: "com.apple.Music",
            isExplicit: true,
            isFavorite: true
        ),
        route: homePod
    )
}

#Preview("Expanded · Paused") {
    expanded(track(.paperLanterns, title: "Paper Lanterns", artist: "Ida Renn", isPlaying: false))
}

#Preview("Expanded · Podcast") {
    expanded(
        track(
            .paperLanterns,
            title: "Episode 112: Building for the Notch",
            artist: "Side Project Radio",
            albumName: "",
            app: "com.apple.podcasts",
            elapsed: 1260,
            duration: 3480
        ),
        route: airPodsPro
    )
}

#Preview("Expanded · Live Radio") {
    expanded(track(.slowOrbit, title: "Morning Mix", artist: "KXPN Live", albumName: "", duration: 0))
}

#Preview("Expanded · Apple TV, App Icon for Artwork") {
    expanded(track(nil, title: "Severance", artist: "S2, E3: Who Is Alive?", albumName: "", app: "com.apple.TV", elapsed: 1290, duration: 2940))
}

#Preview("Expanded · Netflix in Safari, No Position") {
    expanded(track(nil, title: "Netflix", artist: "", albumName: "", app: "com.apple.Safari", elapsed: nil, duration: 0))
}

#Preview("Expanded · Long Title, No Artwork") {
    expanded(
        track(
            nil,
            title: "A Very Long Song Title That Has to Scroll Across the Island to Be Read",
            artist: "Somebody With an Equally Long Artist Name",
            albumName: "Deluxe Edition (Remastered)"
        )
    )
}
#endif
