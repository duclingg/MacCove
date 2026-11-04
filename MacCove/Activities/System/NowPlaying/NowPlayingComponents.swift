//
//  NowPlayingComponents.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import SwiftUI

extension ShapeStyle where Self == Color {
    /// Apple's secondary label colour on dark material: rgba(235, 235, 245, 0.6).
    static var islandSecondary: Color {
        Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.6)
    }

    /// Apple's tertiary label colour on dark material, for captions.
    static var islandTertiary: Color {
        Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.38)
    }
}

/// Album art that flips over like a card, around its vertical axis, and
/// blurs into the next track's cover, as on the iPhone's Dynamic Island.
///
/// A new track's art usually arrives a moment after its title, and the
/// model has no art in between. The old cover stays up through that gap and
/// only flips once the new one is ready, so the flip never lands on the
/// app's icon; that only shows once a track has turned out to have no art
/// at all.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Shown whole, without a tile, when there's no artwork: the playing
    /// app's icon, as on the iPhone.
    var fallbackIcon: NSImage?

    /// What's drawn, which lags `image` while new art is on its way and
    /// while the old art turns away.
    @State private var displayedImage: NSImage?
    /// The art to turn to. Kept up to date mid-flip, in case a newer cover
    /// arrives while the old one is turning away.
    @State private var pendingImage: NSImage?
    /// Bumped for each new cover, which starts a flip.
    @State private var flips = 0
    @State private var swapTask: Task<Void, Never>?
    @State private var fallbackTask: Task<Void, Never>?

    /// How long the old cover waits for the next one before giving way to
    /// the app's icon.
    private static let artworkGrace: Duration = .seconds(2)

    init(image: NSImage?, size: CGFloat, cornerRadius: CGFloat, fallbackIcon: NSImage? = nil) {
        self.image = image
        self.size = size
        self.cornerRadius = cornerRadius
        self.fallbackIcon = fallbackIcon
        _displayedImage = State(initialValue: image)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let peakBlur = size * 0.12

        artwork
            // Turn the old art edge-on as it blurs, jump to the far side,
            // then turn the new art face-on, coming into focus, with a
            // little settle.
            .keyframeAnimator(initialValue: FlipFrame(), trigger: flips) { content, frame in
                content
                    .blur(radius: frame.blur)
                    .clipShape(shape)
                    .rotation3DEffect(.degrees(frame.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            } keyframes: { _ in
                KeyframeTrack(\.angle) {
                    CubicKeyframe(90, duration: Self.halfFlip)
                    MoveKeyframe(-90)
                    SpringKeyframe(0, duration: 0.34, spring: .bouncy)
                }
                KeyframeTrack(\.blur) {
                    CubicKeyframe(peakBlur, duration: Self.halfFlip)
                    CubicKeyframe(0, duration: 0.3)
                }
            }
            .frame(width: size, height: size)
            .onChange(of: image) { _, newImage in
                fallbackTask?.cancel()
                guard newImage == nil, displayedImage != nil else {
                    show(newImage)
                    return
                }
                fallbackTask = Task {
                    try? await Task.sleep(for: Self.artworkGrace)
                    guard !Task.isCancelled, image == nil else { return }
                    show(nil)
                }
            }
            .onDisappear {
                fallbackTask?.cancel()
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let displayedImage {
            Image(nsImage: displayedImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
        } else if let fallbackIcon {
            Image(nsImage: fallbackIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            ZStack {
                Color(white: 0.2)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.islandSecondary)
            }
            .frame(width: size, height: size)
        }
    }

    /// Swaps the art while it's edge-on, so the new art only appears on
    /// the far side of the flip.
    private func show(_ newImage: NSImage?) {
        pendingImage = newImage
        guard swapTask == nil, newImage !== displayedImage else { return }
        flips += 1
        swapTask = Task {
            try? await Task.sleep(for: .seconds(Self.halfFlip))
            displayedImage = pendingImage
            swapTask = nil
        }
    }

    nonisolated private static let halfFlip = 0.18
}

/// Where a flip of `ArtworkView` is up to.
private struct FlipFrame {
    var angle: Double = 0
    var blur: CGFloat = 0
}

/// Four-bar level meter that dances while audio plays and rests flat when paused.
struct AudioBars: View {
    let isPlaying: Bool
    let color: Color

    private static let interval = 0.14
    private static let restingLevels: [CGFloat] = [3, 3, 3, 3]

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(.periodic(from: .now, by: Self.interval)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.interval)
                    LevelBarsShape(levels: Self.levels(tick: tick))
                        .fill(color)
                        .animation(.linear(duration: Self.interval), value: tick)
                }
            } else {
                LevelBarsShape(levels: Self.restingLevels)
                    .fill(color)
            }
        }
        .frame(width: LevelBarsShape.width, height: 18)
        .accessibilityHidden(true)
    }

    /// Cheap deterministic pseudo-random heights between 4 and 18 points.
    private static func levels(tick: Int) -> [CGFloat] {
        (0..<4).map { bar in
            var x = UInt64(truncatingIfNeeded: tick &* 4 &+ bar) &+ 0x9E37_79B9_7F4A_7C15
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            x ^= x >> 31
            return 4 + CGFloat(x % 15)
        }
    }
}

/// The meter's bars as one shape. Animating the bar heights as shape data
/// only redraws the path; changing frame heights would re-lay out the whole
/// island several times a second, mid-spring.
nonisolated struct LevelBarsShape: Shape {
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2.5
    static let width = barWidth * 4 + spacing * 3

    private var first: CGFloat
    private var second: CGFloat
    private var third: CGFloat
    private var fourth: CGFloat

    init(levels: [CGFloat]) {
        first = levels[0]
        second = levels[1]
        third = levels[2]
        fourth = levels[3]
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(first, second), AnimatablePair(third, fourth)) }
        set {
            first = newValue.first.first
            second = newValue.first.second
            third = newValue.second.first
            fourth = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = CGSize(width: Self.barWidth / 2, height: Self.barWidth / 2)
        for (index, level) in [first, second, third, fourth].enumerated() {
            let height = min(max(level, Self.barWidth), rect.height)
            let x = rect.minX + CGFloat(index) * (Self.barWidth + Self.spacing)
            path.addRoundedRect(
                in: CGRect(x: x, y: rect.midY - height / 2, width: Self.barWidth, height: height),
                cornerSize: corner
            )
        }
        return path
    }
}

/// A 44pt circular icon button with the island's hover highlight.
struct IslandIconButton: View {
    let systemName: String
    let size: CGFloat
    let label: String
    var tint: Color = .white
    let action: () -> Void

    /// The hover circle is wider than the 44pt button so even the play
    /// glyph has room around it. It spills into the gaps around the
    /// controls row without changing the layout.
    private static let hoverDiameter: CGFloat = 52

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(.white.opacity(isHovering ? 0.12 : 0))
                        .frame(width: Self.hoverDiameter, height: Self.hoverDiameter)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityLabel(label)
    }
}

/// Elapsed time, a scrubbable progress track and time remaining.
struct PlaybackProgressView: View {
    static let height: CGFloat = 18

    let nowPlaying: NowPlayingModel

    @State private var scrubFraction: Double?

    var body: some View {
        Group {
            if nowPlaying.isLive {
                liveRow
            } else if nowPlaying.hasTimeline {
                timeline
            } else {
                noTimelineRow
            }
        }
        // Line the clock up with the player's own playhead while visible:
        // straight away, after play/pause, then every few seconds.
        .task(id: "\(nowPlaying.track?.id ?? "")-\(nowPlaying.isPlaying)") {
            while !Task.isCancelled {
                await nowPlaying.syncPositionWithPlayer()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    /// Radio and live video have no length: a full, still bar and a red
    /// "LIVE", as on the iPhone.
    private var liveRow: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(height: 5)
            HStack(spacing: 5) {
                Circle()
                    .frame(width: 6, height: 6)
                Text("LIVE")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }

    /// Some web players, Netflix's among them, report no length or
    /// position: an empty, still bar with no times, since there's nothing
    /// to count.
    private var noTimelineRow: some View {
        Capsule()
            .fill(.white.opacity(0.2))
            .frame(height: 5)
            .frame(height: Self.height)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var timeline: some View {
        // Redrawn continuously while playing so the bar glides and the clock
        // ticks the moment each second passes.
        let schedule = AnimationTimelineSchedule(
            minimumInterval: 1.0 / 30,
            paused: !nowPlaying.isPlaying || scrubFraction != nil
        )
        TimelineView(schedule) { context in
            let duration = nowPlaying.duration
            let elapsed = scrubFraction.map { $0 * duration } ?? nowPlaying.elapsed(at: context.date)
            let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
            // Count both labels in whole seconds so they tick together.
            let wholeElapsed = elapsed.rounded(.down)
            let remaining = max(duration.rounded() - wholeElapsed, 0)

            HStack(spacing: 10) {
                Text(Self.format(wholeElapsed))
                    .frame(width: 36, alignment: .leading)
                track(fraction: fraction, duration: duration)
                Text(duration > 0 ? "-" + Self.format(remaining) : "--:--")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.islandSecondary)
            .frame(height: Self.height)
        }
    }

    private func track(fraction: Double, duration: TimeInterval) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Capsule()
                .fill(.white.opacity(0.2))
                .overlay {
                    Rectangle()
                        .fill(.white)
                        .scaleEffect(x: fraction, y: 1, anchor: .leading)
                }
                .clipShape(Capsule())
                .frame(height: scrubFraction == nil ? 5 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0, width > 0 else { return }
                            scrubFraction = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { _ in
                            if let scrubFraction {
                                nowPlaying.seek(to: scrubFraction * duration)
                            }
                            scrubFraction = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: scrubFraction == nil)
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Self.format(fraction * duration))
    }

    static func format(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded(.down)), 0)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// One line of text that scrolls when it doesn't fit, like the iPhone's
/// player: it rests, glides left until a second copy takes its place, and
/// repeats, fading at the edges while it overflows. Text that fits stays
/// still, and the view is only as wide as the text, so a badge after it
/// sits right at the end.
struct MarqueeText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private static let gap: CGFloat = 36
    private static let pointsPerSecond: CGFloat = 30
    private static let pause: Duration = .seconds(2.5)

    private var overflows: Bool {
        textWidth > boxWidth + 0.5
    }

    var body: some View {
        // Sizes the box: as wide as the text, or the space available.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                boxWidth = width
            }
            .overlay(alignment: .leading) {
                HStack(spacing: Self.gap) {
                    label
                    if overflows {
                        label
                    }
                }
                .offset(x: offset)
            }
            .clipped()
            .mask {
                LinearGradient(stops: fadeStops, startPoint: .leading, endPoint: .trailing)
            }
            .task(id: "\(text)|\(overflows)") {
                await scroll()
            }
            .accessibilityElement()
            .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                textWidth = width
            }
    }

    /// Fades the trailing edge while text runs past it, and the leading edge
    /// while it's scrolling.
    private var fadeStops: [Gradient.Stop] {
        let leading: CGFloat = overflows && offset < 0 ? 0.05 : 0
        let trailing: CGFloat = overflows ? 0.06 : 0
        return [
            .init(color: leading > 0 ? .clear : .black, location: 0),
            .init(color: .black, location: leading),
            .init(color: .black, location: 1 - trailing),
            .init(color: trailing > 0 ? .clear : .black, location: 1),
        ]
    }

    private func scroll() async {
        offset = 0
        guard overflows else { return }
        let distance = textWidth + Self.gap
        let duration = Double(distance / Self.pointsPerSecond)
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) {
                offset = -distance
            }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // The second copy is now exactly where the first started, so
            // jumping back is invisible.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                offset = 0
            }
        }
    }
}
