import SwiftUI

enum IslandState {
    /// Nothing to show: the island hides behind the camera housing.
    case idle
    /// Live activity tucked beside the notch.
    case compact
    /// Full controls, opened by clicking the island.
    case expanded
}

/// A system event that takes the island over, ahead of Now Playing, as on
/// the iPhone.
enum IslandAlert: Equatable {
    /// "Charging" beside the notch while the battery fills up.
    case charging
    /// The level and a button for Low Power Mode, or its confirmation.
    case lowBattery
    /// A Touch ID or password prompt. Stays for as long as the prompt does,
    /// and ahead of the battery alerts.
    case signIn

    /// How long a battery alert stays; a sign-in leaves with its prompt.
    var duration: Duration {
        switch self {
        case .charging: .seconds(3)
        case .lowBattery: .seconds(6)
        case .signIn: .zero
        }
    }
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
    /// Shown in place of Now Playing until it times out.
    private(set) var alert: IslandAlert?

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

    var state: IslandState {
        guard nowPlaying.hasMedia || alert != nil else { return .idle }
        // Brought back on purpose: shown whatever else is going on.
        if isRevealedByHover { return presentation }
        // A prompt answers something you just did, so it shows in full
        // screen too.
        if isFullScreenActive, alert != .signIn { return .idle }
        if alert == nil, presentation == .compact, isDismissedForPause { return .idle }
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
        case .compact where alert == .signIn:
            let grow: CGSize = isHovering ? CGSize(width: 8, height: 3) : .zero
            return IslandGeometry(
                size: CGSize(width: Self.signInWidth(notch: notch, prompt: signIn.prompt) + grow.width, height: notch.height + grow.height),
                cornerRadius: Self.compactCornerRadius,
                isLifted: false
            )
        case .expanded where alert == .signIn:
            return IslandGeometry(
                size: CGSize(width: SignInExpandedView.width, height: notch.height + SignInExpandedView.bodyHeight),
                cornerRadius: SignInExpandedView.cornerRadius,
                isLifted: true
            )
        case .compact where alert == .lowBattery:
            return IslandGeometry(
                size: CGSize(width: Self.expandedWidth, height: notch.height + Self.alertBodyHeight),
                cornerRadius: Self.alertCornerRadius,
                isLifted: true
            )
        case .compact:
            let grow: CGSize = isHovering ? CGSize(width: 8, height: 3) : .zero
            let width = alert == .charging ? Self.chargingWidth(notch: notch) : Self.compactWidth(notch: notch)
            return IslandGeometry(
                size: CGSize(width: width + grow.width, height: notch.height + grow.height),
                cornerRadius: Self.compactCornerRadius,
                isLifted: false
            )
        case .expanded:
            let body = alert == nil ? Self.expandedBodyHeight : BatteryExpandedView.bodyHeight
            return IslandGeometry(size: CGSize(width: Self.expandedWidth, height: notch.height + body), cornerRadius: Self.expandedCornerRadius, isLifted: true)
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
    /// fingerprint or check on the right, or, while typing, room for six
    /// dots or "Password".
    static let signInWingWidth: CGFloat = 56
    static let passwordWingWidth: CGFloat = 77

    static func signInWidth(notch: CGSize, prompt: SignInMonitor.Prompt?) -> CGFloat {
        if case .password? = prompt {
            return notch.width + passwordWingWidth * 2
        }
        return notch.width + signInWingWidth * 2
    }

    // MARK: - Interaction

    func expand() {
        // Nothing opens on the lock screen, where it would cover the clock.
        guard !signIn.isScreenLocked else { return }
        collapseTask?.cancel()
        alertTask?.cancel()
        presentation = .expanded
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        scheduleCollapseIfNeeded()
        // An alert stays while the cursor is on it, then leaves shortly after.
        if hovering {
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
        setHovering(true)
    }

    private func batteryEvent(_ event: BatteryMonitor.Event) {
        switch event {
        case .pluggedIn:
            showAlert(.charging, for: IslandAlert.charging.duration)
        case .lowBattery:
            showAlert(.lowBattery, for: IslandAlert.lowBattery.duration)
        case .lowPowerModeEnabled:
            // Confirms the button just clicked briefly, or announces it being
            // turned on elsewhere.
            showAlert(.lowBattery, for: alert == .lowBattery ? .seconds(2.5) : .seconds(4))
        }
    }

    /// Takes over the island as the prompt appears, and leaves with it. It
    /// opens into the square only when clicked, and never on the lock
    /// screen, where the square would cover the clock.
    private func signInChanged(_ prompt: SignInMonitor.Prompt?) {
        guard prompt != nil else {
            guard alert == .signIn else { return }
            collapseTask?.cancel()
            alertTask?.cancel()
            alert = nil
            presentation = .compact
            return
        }

        if alert != .signIn {
            collapseTask?.cancel()
            alertTask?.cancel()
            alert = .signIn
            presentation = .compact
        }
        if signIn.isScreenLocked {
            collapseTask?.cancel()
            presentation = .compact
        }
    }

    /// Takes over the island, unless the battery details are already open,
    /// in which case they just update. A sign-in prompt stays in front.
    private func showAlert(_ newAlert: IslandAlert, for duration: Duration) {
        guard alert != .signIn else { return }
        let isShowingDetails = alert != nil && presentation == .expanded
        alert = newAlert
        if !isShowingDetails {
            collapseTask?.cancel()
            presentation = .compact
        }
        scheduleAlertDismissal(after: duration)
    }

    /// Never while the cursor is on the island or the details are open;
    /// leaving schedules it again.
    private func scheduleAlertDismissal(after delay: Duration) {
        alertTask?.cancel()
        // A sign-in times itself, by its prompt.
        guard alert != nil, alert != .signIn else { return }
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isHovering, self.presentation != .expanded else { return }
            self.alert = nil
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
