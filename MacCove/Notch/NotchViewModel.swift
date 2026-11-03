import SwiftUI

enum IslandState {
    /// Nothing to show: the island hides behind the camera housing.
    case idle
    /// Live activity tucked beside the notch.
    case compact
    /// Full controls, opened by clicking the island.
    case expanded
}

/// Something the island shows. Several can run at once, as on the iPhone:
/// the first takes the island and the rest wait in bubbles beside it.
enum IslandActivity: Hashable {
    /// Touch ID on the lock screen. Stays until the unlock has played,
    /// alone and only ever as the pill.
    case signIn
    /// The level and a button for Low Power Mode, or its confirmation.
    case lowBattery
    /// "Charging" beside the notch while the battery fills up.
    case charging
    case nowPlaying

    /// How long a battery alert stays; the others leave by themselves.
    var duration: Duration {
        switch self {
        case .charging: .seconds(3)
        case .lowBattery: .seconds(6)
        case .signIn, .nowPlaying: .zero
        }
    }
}

/// An activity waiting beside the island, in a bubble of its own.
struct IslandBubble: Equatable, Identifiable {
    let activity: IslandActivity
    /// From the top of the screen, with x measured from the island's
    /// centre line.
    let frame: CGRect

    var id: IslandActivity { activity }
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
    let battery: BatteryMonitor
    let signIn: SignInMonitor

    var notchSize = CGSize(width: 186, height: 37)
    var hasPhysicalNotch = true

    /// The island or bubble under the cursor.
    private(set) var hovered: IslandActivity?
    private var presentation: IslandState = .compact
    /// What was clicked open, which leads while the island is expanded.
    private var expandedActivity: IslandActivity?
    /// Paused media steps out of the way, like the iPhone: it stays while
    /// you're using the expanded player, but not as a compact pill.
    private var isDismissedForPause = false
    /// Brought back on purpose through the hover strip while it would
    /// otherwise be tucked away.
    private var isRevealedByHover = false
    /// A full-screen app is in front on this display: the island steps
    /// aside, as on the iPhone.
    private var isFullScreenActive = false
    private var isSigningIn = false
    /// The charging pill or the low battery alert, until it times out.
    private var batteryAlert: IslandActivity?

    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var alertTask: Task<Void, Never>?

    init(nowPlaying: NowPlayingModel, audioRoute: AudioRouteMonitor, battery: BatteryMonitor, signIn: SignInMonitor) {
        self.nowPlaying = nowPlaying
        self.audioRoute = audioRoute
        self.battery = battery
        self.signIn = signIn
        isDismissedForPause = !nowPlaying.isPlaying
        nowPlaying.onPlayingChange = { [weak self] playing in
            self?.playbackChanged(playing: playing)
        }
        battery.onEvent = { [weak self] event in
            self?.batteryEvent(event)
        }
        signIn.onChange = { [weak self] prompt in
            self?.signInChanged(prompt)
        }
    }

    /// Most that run at once: one in the island and two in bubbles.
    static let maxActivities = 3

    /// What's running, the island's first and the rest for the bubbles.
    var activities: [IslandActivity] {
        // A full-screen app hides everything but the lock screen, unless the
        // island was brought back on purpose.
        let isShowingAll = !isFullScreenActive || isRevealedByHover
        // The lock screen and battery alerts take the whole island to
        // themselves. The lock screen shows over full-screen apps too.
        if isSigningIn {
            return [.signIn]
        }
        if let batteryAlert {
            return isShowingAll ? [batteryAlert] : []
        }
        var running: [IslandActivity] = []
        if isShowingAll, isNowPlayingShown {
            running.append(.nowPlaying)
        }
        if presentation == .expanded, let expandedActivity, let index = running.firstIndex(of: expandedActivity) {
            running.insert(running.remove(at: index), at: 0)
        }
        return Array(running.prefix(Self.maxActivities))
    }

    var primaryActivity: IslandActivity? {
        activities.first
    }

    var state: IslandState {
        guard let primary = primaryActivity else { return .idle }
        // Whatever was opened has to still be running to stay open, and in
        // front: locking the screen closes it.
        if presentation == .expanded, primary == expandedActivity { return .expanded }
        return .compact
    }

    /// Paused media steps aside, unless you're using the player or brought
    /// it back through the hover strip.
    private var isNowPlayingShown: Bool {
        guard nowPlaying.hasMedia else { return false }
        return !isDismissedForPause || isRevealedByHover || (presentation == .expanded && expandedActivity == .nowPlaying)
    }

    var isHovering: Bool {
        hovered != nil
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
        let primary = primaryActivity
        let grow: CGSize = hovered != nil && hovered == primary ? Self.hoverGrowth : .zero
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
        case .compact where primary == .signIn:
            return IslandGeometry(
                size: CGSize(width: Self.signInWidth(notch: notch) + grow.width, height: notch.height + grow.height),
                cornerRadius: Self.compactCornerRadius,
                isLifted: false
            )
        case .compact where primary == .lowBattery:
            return IslandGeometry(
                size: CGSize(width: Self.expandedWidth, height: notch.height + Self.alertBodyHeight),
                cornerRadius: Self.alertCornerRadius,
                isLifted: true
            )
        case .compact:
            let width = primary == .charging ? Self.chargingWidth(notch: notch) : Self.compactWidth(notch: notch)
            return IslandGeometry(
                size: CGSize(width: width + grow.width, height: notch.height + grow.height),
                cornerRadius: Self.compactCornerRadius,
                isLifted: false
            )
        case .expanded:
            let body = primary == .nowPlaying ? Self.expandedBodyHeight : BatteryExpandedView.bodyHeight
            return IslandGeometry(size: CGSize(width: Self.expandedWidth, height: notch.height + body), cornerRadius: Self.expandedCornerRadius, isLifted: true)
        }
    }

    /// The second activity on the right of the pill, as on the iPhone, and
    /// a third on the left. Never beside the open island.
    var bubbles: [IslandBubble] {
        guard state == .compact else { return [] }
        let islandWidth = geometry.size.width
        return activities.dropFirst().enumerated().map { index, activity in
            let grow: CGFloat = hovered == activity ? Self.bubbleHoverGrowth : 0
            let size = CGSize(width: notchSize.height + grow, height: notchSize.height + grow)
            let distance = islandWidth / 2 + Self.bubbleGap + size.width / 2
            let midX = index == 0 ? distance : -distance
            return IslandBubble(
                activity: activity,
                frame: CGRect(x: midX - size.width / 2, y: 0, width: size.width, height: size.height)
            )
        }
    }

    // MARK: - Layout constants from the design

    /// Height of the invisible strip along the top edge that brings a
    /// tucked-away island back on screens without a notch.
    static let hoverStripHeight: CGFloat = 5
    static let compactCornerRadius: CGFloat = 12
    /// How much the pill grows under the cursor.
    static let hoverGrowth = CGSize(width: 8, height: 3)
    /// Between the pill and a bubble, enough for the two to read as
    /// separate shapes.
    static let bubbleGap: CGFloat = 8
    static let bubbleHoverGrowth: CGFloat = 3
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

    /// Each wing of the charging pill: room for "Charging" on the left and
    /// "100%" with the battery on the right.
    static let chargingWingWidth: CGFloat = 104
    /// The low battery alert, under the notch row: the text and the 57pt
    /// Low Power Mode button with their gaps.
    static let alertTopGap: CGFloat = 8
    static let alertBodyHeight: CGFloat = alertTopGap + 57 + 14
    static let alertCornerRadius: CGFloat = 38

    static func compactWidth(notch: CGSize) -> CGFloat {
        notch.width + CompactLayout(notch: notch).wingWidth * 2
    }

    static func chargingWidth(notch: CGSize) -> CGFloat {
        notch.width + chargingWingWidth * 2
    }

    /// Each wing of the sign-in pill: the lock on the left and the
    /// fingerprint or check on the right.
    static let signInWingWidth: CGFloat = 56

    static func signInWidth(notch: CGSize) -> CGFloat {
        notch.width + signInWingWidth * 2
    }

    // MARK: - Interaction

    /// Opens the activity clicked: the island's own, or one from a bubble.
    func expand(_ activity: IslandActivity? = nil) {
        guard let activity = activity ?? primaryActivity, activity != .signIn else { return }
        collapseTask?.cancel()
        alertTask?.cancel()
        expandedActivity = activity
        presentation = .expanded
    }

    /// The island or bubble under the cursor, `nil` for neither.
    func setHovering(_ activity: IslandActivity?) {
        guard activity != hovered else { return }
        let wasHovering = isHovering
        hovered = activity
        // Moving between the island and a bubble is still hovering.
        guard isHovering != wasHovering else { return }
        scheduleCollapseIfNeeded()
        // An alert stays while the cursor is on it, then leaves shortly after.
        if isHovering {
            alertTask?.cancel()
        } else if presentation == .compact {
            scheduleAlertDismissal(after: .seconds(1.2))
        }
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
        setHovering(primaryActivity)
    }

    private func batteryEvent(_ event: BatteryMonitor.Event) {
        switch event {
        case .pluggedIn:
            showAlert(.charging, for: IslandActivity.charging.duration)
        case .lowBattery:
            showAlert(.lowBattery, for: IslandActivity.lowBattery.duration)
        case .lowPowerModeEnabled:
            // Confirms the button just clicked briefly, or announces it being
            // turned on elsewhere.
            showAlert(.lowBattery, for: batteryAlert == .lowBattery ? .seconds(2.5) : .seconds(4))
        }
    }

    /// Takes over the island as the screen locks, replacing any battery
    /// alert, and leaves once the unlock has played.
    private func signInChanged(_ prompt: SignInMonitor.Prompt?) {
        guard prompt != nil else {
            guard isSigningIn else { return }
            collapseTask?.cancel()
            isSigningIn = false
            presentation = .compact
            return
        }

        if !isSigningIn {
            collapseTask?.cancel()
            alertTask?.cancel()
            isSigningIn = true
            batteryAlert = nil
            presentation = .compact
        }
    }

    /// Takes over the island, unless the battery details are already open,
    /// in which case they just update. The lock screen stays in front.
    private func showAlert(_ newAlert: IslandActivity, for duration: Duration) {
        guard !isSigningIn else { return }
        let isShowingDetails = batteryAlert != nil && state == .expanded
        batteryAlert = newAlert
        if isShowingDetails {
            // Both alerts open the same details.
            expandedActivity = newAlert
        } else {
            collapseTask?.cancel()
            presentation = .compact
        }
        scheduleAlertDismissal(after: duration)
    }

    /// Never while the cursor is on the island or the details are open;
    /// leaving schedules it again.
    private func scheduleAlertDismissal(after delay: Duration) {
        alertTask?.cancel()
        guard batteryAlert != nil else { return }
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isHovering, self.presentation != .expanded else { return }
            self.batteryAlert = nil
        }
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
    /// an island brought back by the hover strip tucks away again. Battery
    /// details go back to the alert, which then leaves too.
    private func scheduleCollapseIfNeeded() {
        collapseTask?.cancel()
        guard !isHovering, presentation == .expanded || isRevealedByHover else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.presentation = .compact
            self.isRevealedByHover = false
            self.scheduleAlertDismissal(after: .seconds(1.2))
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
