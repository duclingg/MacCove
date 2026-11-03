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
        if presentation == .compact, isDismissedForPause, !isRevealedByHover { return .idle }
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
            return IslandGeometry(size: CGSize(width: Self.expandedWidth, height: notch.height + Self.expandedBodyHeight), cornerRadius: 28, isLifted: true)
        }
    }

    // MARK: - Layout constants from the design

    static let compactWingWidth: CGFloat = 56
    /// Height of the invisible strip along the top edge that brings a
    /// tucked-away island back on screens without a notch.
    static let hoverStripHeight: CGFloat = 5
    static let compactCornerRadius: CGFloat = 12
    static let expandedWidth: CGFloat = 452
    /// Gap from the island's side, and from the notch, to the artwork.
    static let expandedInset: CGFloat = 20
    static let expandedHeaderGap: CGFloat = 16
    static let expandedControlsGap: CGFloat = 10
    /// Gap under the notch, then the artwork (64), the progress row (18) and
    /// the controls (44) with their gaps, then 12 at the bottom. The 44pt
    /// buttons leave empty space under their glyphs, so the visible bottom
    /// margin roughly matches the 20pt side inset.
    static let expandedBodyHeight: CGFloat = expandedInset + 64 + expandedHeaderGap + PlaybackProgressView.height
        + expandedControlsGap + 44 + 12

    static func compactWidth(notch: CGSize) -> CGFloat {
        notch.width + compactWingWidth * 2
    }

    /// The same gap above, beside and below the compact artwork. The design's
    /// 24pt artwork on a 37pt notch leaves 6pt; shorter notches shrink the
    /// artwork rather than the gap.
    static func compactInset(notch: CGSize) -> CGFloat {
        max(5, ((notch.height - 24) / 2).rounded(.down))
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
