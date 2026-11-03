import SwiftUI

enum IslandState {
    /// Nothing to show: the island hides behind the camera housing.
    case idle
    /// Live activity tucked beside the notch.
    case compact
    /// Full controls, opened by clicking the island.
    case expanded
}

struct IslandGeometry: Equatable {
    var size: CGSize
    var cornerRadius: CGFloat
    /// Larger states float above the desktop with a drop shadow.
    var isLifted: Bool
}

@Observable
final class NotchViewModel {
    let nowPlaying: NowPlayingModel
    let audioRoute: AudioRouteMonitor

    var notchSize = CGSize(width: 186, height: 37)
    var hasPhysicalNotch = true

    private(set) var isHovering = false
    private var presentation: IslandState = .compact
    /// Paused media steps out of the way, like the iPhone: it stays while
    /// you're using the expanded player, but not as a compact pill.
    private var isDismissedForPause = false
    /// Brought back on purpose through the hover strip while it would
    /// otherwise be tucked away.
    private var isRevealedByHover = false
    /// A full-screen app is in front on this display: the island steps
    /// aside, as on the iPhone.
    private var isFullScreenActive = false

    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?

    init(nowPlaying: NowPlayingModel, audioRoute: AudioRouteMonitor) {
        self.nowPlaying = nowPlaying
        self.audioRoute = audioRoute
        isDismissedForPause = !nowPlaying.isPlaying
        nowPlaying.onPlayingChange = { [weak self] playing in
            self?.playbackChanged(playing: playing)
        }
    }

    var state: IslandState {
        guard nowPlaying.hasMedia else { return .idle }
        // Brought back on purpose: shown whatever else is going on.
        if isRevealedByHover { return presentation }
        if isFullScreenActive { return .idle }
        if presentation == .compact, isDismissedForPause { return .idle }
        return presentation
    }

    /// Without a camera housing to hide behind, an idle island would be a
    /// floating black pill, so it slides up off the top of the screen
    /// instead.
    var isTuckedAway: Bool {
        state == .idle && !hasPhysicalNotch
    }

    /// Whether the hover strip has anything to bring back: the island is
    /// tucked away but media is still around (paused, say).
    var canRevealOnHover: Bool {
        isTuckedAway && nowPlaying.hasMedia
    }

    var geometry: IslandGeometry {
        let notch = notchSize
        switch state {
        case .idle where hasPhysicalNotch:
            return IslandGeometry(size: notch, cornerRadius: 10, isLifted: false)
        case .idle:
            // Keeps its compact shape so it slides out of sight whole,
            // rather than shrinking as it goes.
            return IslandGeometry(
                size: CGSize(width: Self.compactWidth(notch: notch), height: notch.height),
                cornerRadius: Self.compactCornerRadius,
                isLifted: false
            )
        case .compact:
            let grow: CGSize = isHovering ? CGSize(width: 8, height: 3) : .zero
            return IslandGeometry(
                size: CGSize(width: Self.compactWidth(notch: notch) + grow.width, height: notch.height + grow.height),
                cornerRadius: Self.compactCornerRadius,
                isLifted: false
            )
        case .expanded:
            return IslandGeometry(size: CGSize(width: Self.expandedWidth, height: notch.height + Self.expandedBodyHeight), cornerRadius: Self.expandedCornerRadius, isLifted: true)
        }
    }

    // MARK: - Layout constants from the design

    /// Height of the invisible strip along the top edge that brings a
    /// tucked-away island back on screens without a notch.
    static let hoverStripHeight: CGFloat = 5
    static let compactCornerRadius: CGFloat = 12
    static let expandedWidth: CGFloat = 420
    static let expandedCornerRadius: CGFloat = 32
    /// Gap from the island's sides to the content.
    static let expandedInset: CGFloat = 20
    /// Gap from the notch to the artwork. Small, since the notch row above
    /// is already solid black.
    static let expandedTopGap: CGFloat = 10
    static let expandedHeaderGap: CGFloat = 12
    static let expandedControlsGap: CGFloat = 6
    static let expandedBottomGap: CGFloat = 10
    /// Everything under the notch: the artwork (64), the progress row and the
    /// controls (44) with their gaps. The 44pt buttons leave empty space
    /// under their glyphs, so the bottom looks roomier than its 10pt.
    static let expandedBodyHeight: CGFloat = expandedTopGap + 64 + expandedHeaderGap + PlaybackProgressView.height
        + expandedControlsGap + 44 + expandedBottomGap

    static func compactWidth(notch: CGSize) -> CGFloat {
        notch.width + CompactLayout(notch: notch).wingWidth * 2
    }

    // MARK: - Interaction

    func expand() {
        collapseTask?.cancel()
        presentation = .expanded
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        scheduleCollapseIfNeeded()
    }

    /// Entering full screen closes the player too, so it doesn't come back
    /// expanded when you leave.
    func setFullScreenActive(_ active: Bool) {
        guard active != isFullScreenActive else { return }
        isFullScreenActive = active
        if active {
            collapseTask?.cancel()
            presentation = .compact
            isRevealedByHover = false
        }
    }

    /// The cursor reached the hover strip: slide the island down under it.
    func revealFromHoverStrip() {
        guard canRevealOnHover else { return }
        isRevealedByHover = true
        setHovering(true)
    }

    /// A short grace period, so a quick pause-and-resume doesn't make the
    /// island flicker away and back.
    private func playbackChanged(playing: Bool) {
        pauseTask?.cancel()
        guard !playing else {
            isDismissedForPause = false
            return
        }
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.nowPlaying.isPlaying else { return }
            self.isDismissedForPause = true
        }
    }

    /// Half a second after the cursor leaves, the expanded player closes and
    /// an island brought back by the hover strip tucks away again.
    private func scheduleCollapseIfNeeded() {
        collapseTask?.cancel()
        guard !isHovering, presentation == .expanded || isRevealedByHover else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.presentation = .compact
            self.isRevealedByHover = false
        }
    }
}

extension Animation {
    /// Matches the design's cubic-bezier(.3, 1.2, .5, 1) over 0.46s: quick with a slight overshoot.
    static let island = Animation.spring(duration: 0.46, bounce: 0.22)
    /// Sliding in from and out past the screen edge: as quick, but critically
    /// damped so it lands flush against the edge without overshooting.
    static let islandSlide = Animation.spring(duration: 0.42, bounce: 0)
}

/// Sizes in the collapsed island, in the iPhone's proportions and scaled to
/// the notch height. On a 37pt island: 23pt artwork with 7pt above and below
/// and 9pt to the side, and the same square mirrored on the right.
struct CompactLayout {
    let artSize: CGFloat
    let verticalInset: CGFloat
    let sideInset: CGFloat
    /// Each side of the notch: the side inset, the artwork, and a gap
    /// before the notch.
    let wingWidth: CGFloat

    init(notch: CGSize) {
        let height = notch.height
        artSize = (height * 0.62).rounded()
        verticalInset = (height - artSize) / 2
        // A little more at the side, as the iPhone has.
        sideInset = verticalInset + 2
        wingWidth = sideInset + artSize + 12
    }
}
