//
//  NotchViewModel.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

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
    /// An Xcode build, test run or run of the app.
    case xcode
    /// A terminal command that's taking a while, then how it ended.
    case terminal
    /// A Claude Code session: working, waiting for approval, finished.
    case claudeCode
    /// A pull request's checks, or a review someone asked you for.
    case github
    /// Files coming into the Downloads folder, then the last one done.
    case downloads
    /// "Copied" for a moment, or the last few copies.
    case clipboard
    /// The next event from Calendar, when to leave for it, or the rest
    /// of the day.
    case calendar
    /// A reminder that's due, or the day's list when several are.
    case reminders
    /// A mouse, keyboard or controller running low, connecting or
    /// charging, or every device's level.
    case deviceBatteries
    /// The camera, shown only in the notch, while Mirror is open.
    case mirror
    /// Files dropped on the notch, or a file drag on its way to it.
    case shelf
    case nowPlaying

    /// How long a battery alert stays; the others leave by themselves.
    var duration: Duration {
        switch self {
        case .charging: .seconds(3)
        case .lowBattery: .seconds(6)
        case .signIn, .xcode, .terminal, .claudeCode, .github, .downloads, .clipboard, .calendar, .reminders, .deviceBatteries, .mirror, .shelf, .nowPlaying: .zero
        }
    }
}

/// Activities waiting beside the island, one bubble to a side. Two on the
/// same side share it, their glyphs side by side, rather than queueing up
/// in bubbles of their own.
struct IslandBubble: Equatable, Identifiable {
    enum Side {
        case leading
        case trailing
    }

    /// One activity's part of the bubble, which opens it.
    struct Segment: Equatable {
        let activity: IslandActivity
        /// In the same space as the bubble's frame.
        let frame: CGRect
        /// The extras, stacked as mini icons in place of the first of them,
        /// which a click opens. Empty for an activity's own.
        var overflow: [IslandActivity] = []
    }

    let side: Side
    /// From the top of the screen, with x measured from the island's
    /// centre line.
    let frame: CGRect
    /// Left to right, the earlier activity nearest the island.
    let segments: [Segment]
    /// A lone bubble has room for a second glyph beside the first: the
    /// speaker or headphones Now Playing is on, as the iPhone shows it.
    var isWide = false

    /// By side, so a bubble that gains or loses an activity reshapes in
    /// place instead of being swapped for another.
    var id: Side { side }
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
    let xcode: XcodeBuildMonitor
    let terminal: TerminalCommandMonitor
    let claude: ClaudeCodeMonitor
    let github: GitHubMonitor
    let downloads: DownloadMonitor
    let clipboard: ClipboardMonitor
    let calendar: CalendarMonitor
    let reminders: RemindersMonitor
    let deviceBatteries: DeviceBatteryMonitor
    let mirror: MirrorCamera
    let shelf: FileShelf

    var notchSize = CGSize(width: 186, height: 37)
    var hasPhysicalNotch = true
    /// The main display's width in points.
    var screenWidth: CGFloat = 1512

    /// The island or bubble under the cursor.
    private(set) var hovered: IslandActivity?
    /// The cursor is on the notch with nothing running. It grows a little,
    /// as the pill does, but never takes the click.
    private(set) var isIdleNotchHovered = false
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
    /// The app in front is full screen on this display.
    private var isFrontAppFullScreen = false
    /// The front app's full screen hides the notch, unless General says
    /// otherwise.
    private var isFullScreenActive: Bool {
        isFrontAppFullScreen && hidesInFullScreen
    }
    private var isSigningIn = false
    /// The charging pill or the low battery alert, until it times out.
    private var batteryAlert: IslandActivity?
    /// Opened from the mini icons: stays in the first bubble once it
    /// closes, so the next click on them reaches the one after it. Something
    /// new starting puts everything back in order.
    private var promotedActivity: IslandActivity?
    /// Swiped into the notch, as on the iPhone: still running, but out of
    /// sight until swiped back out or until it has something new to show.
    /// The latest last.
    private var hiddenActivities: [IslandActivity] = []

    /// The app in front, and in Terminal or iTerm the terminal device of
    /// the tab in front. An activity steps out of the notch while what it
    /// comes from is in front, as on the iPhone while you're in the app,
    /// and comes back when you switch away.
    struct FrontApp: Equatable {
        var bundleIdentifier: String?
        var tty: String?
    }

    var frontApp: FrontApp?

    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    /// Opening after the cursor has rested on the notch for a moment.
    @ObservationIgnored private var hoverOpenTask: Task<Void, Never>?

    // General's settings, read again whenever they change.
    /// At most this many shown on their own.
    private(set) var maxActivities = NotchSettings.maxActivities
    private var hidesInFullScreen = NotchSettings.hidesInFullScreen
    private var noNotchVisibility = NotchSettings.noNotchVisibility
    private var showsHandleSetting = NotchSettings.showsHandle
    @ObservationIgnored private var opening = NotchSettings.opening
    @ObservationIgnored private var hasTrackpadFeedback = NotchSettings.hasTrackpadFeedback
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var alertTask: Task<Void, Never>?
    /// Closes a failure, or the clipboard history from the menu bar, that
    /// opened by itself.
    @ObservationIgnored private var failureCollapseTask: Task<Void, Never>?

    init(
        nowPlaying: NowPlayingModel,
        audioRoute: AudioRouteMonitor,
        battery: BatteryMonitor,
        signIn: SignInMonitor,
        xcode: XcodeBuildMonitor,
        terminal: TerminalCommandMonitor,
        claude: ClaudeCodeMonitor,
        github: GitHubMonitor,
        downloads: DownloadMonitor,
        clipboard: ClipboardMonitor,
        calendar: CalendarMonitor,
        reminders: RemindersMonitor,
        deviceBatteries: DeviceBatteryMonitor,
        mirror: MirrorCamera,
        shelf: FileShelf
    ) {
        self.nowPlaying = nowPlaying
        self.audioRoute = audioRoute
        self.battery = battery
        self.signIn = signIn
        self.xcode = xcode
        self.terminal = terminal
        self.claude = claude
        self.github = github
        self.downloads = downloads
        self.clipboard = clipboard
        self.calendar = calendar
        self.reminders = reminders
        self.deviceBatteries = deviceBatteries
        self.mirror = mirror
        self.shelf = shelf
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
        xcode.onEvent = { [weak self] event in
            self?.xcodeEvent(event)
        }
        terminal.onEvent = { [weak self] event in
            self?.terminalEvent(event)
        }
        terminal.isInUse = { [weak self] in
            guard let self else { return false }
            return self.isHovering || self.presentation == .expanded
        }
        claude.onEvent = { [weak self] event in
            self?.claudeEvent(event)
        }
        github.onEvent = { [weak self] event in
            self?.githubEvent(event)
        }
        github.isInUse = { [weak self] in
            guard let self else { return false }
            return self.isHovering || self.presentation == .expanded
        }
        downloads.onEvent = { [weak self] event in
            self?.downloadsEvent(event)
        }
        downloads.isInUse = { [weak self] in
            guard let self else { return false }
            return self.isHovering || self.presentation == .expanded
        }
        clipboard.onEvent = { [weak self] event in
            self?.clipboardEvent(event)
        }
        // Only the clipboard's own pill or details: a copy made while you're
        // using the player doesn't wait for you to finish with it.
        clipboard.isInUse = { [weak self] in
            guard let self else { return false }
            return self.hovered == .clipboard || (self.presentation == .expanded && self.expandedActivity == .clipboard)
        }
        calendar.onEvent = { [weak self] event in
            self?.calendarEvent(event)
        }
        calendar.isInUse = { [weak self] in
            guard let self else { return false }
            return self.isHovering || self.presentation == .expanded
        }
        reminders.onEvent = { [weak self] event in
            self?.remindersEvent(event)
        }
        reminders.isInUse = { [weak self] in
            guard let self else { return false }
            return self.isHovering || self.presentation == .expanded
        }
        deviceBatteries.onEvent = { [weak self] event in
            self?.deviceBatteriesEvent(event)
        }
        deviceBatteries.isInUse = { [weak self] in
            guard let self else { return false }
            return self.isHovering || self.presentation == .expanded
        }
        mirror.onEvent = { [weak self] event in
            self?.mirrorEvent(event)
        }
        // Only its own pill or the mirror itself: out of sight, the camera
        // turns off after a while.
        mirror.isInView = { [weak self] in
            guard let self else { return false }
            return self.hovered == .mirror || (self.state == .expanded && self.primaryActivity == .mirror)
        }
        shelf.onEvent = { [weak self] event in
            self?.shelfEvent(event)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSettings() }
        }
    }

    /// General's settings, as they change in Settings.
    private func readSettings() {
        opening = NotchSettings.opening
        hasTrackpadFeedback = NotchSettings.hasTrackpadFeedback
        if maxActivities != NotchSettings.maxActivities {
            maxActivities = NotchSettings.maxActivities
        }
        if noNotchVisibility != NotchSettings.noNotchVisibility {
            noNotchVisibility = NotchSettings.noNotchVisibility
        }
        if showsHandleSetting != NotchSettings.showsHandle {
            showsHandleSetting = NotchSettings.showsHandle
        }
        if hidesInFullScreen != NotchSettings.hidesInFullScreen {
            let wasActive = isFullScreenActive
            hidesInFullScreen = NotchSettings.hidesInFullScreen
            if isFullScreenActive, !wasActive {
                fullScreenBecameActive()
            }
        }
    }

    /// What's shown on its own, the island's first and the rest for the
    /// bubbles.
    var activities: [IslandActivity] {
        Array(runningActivities.prefix(maxActivities))
    }

    /// Running past those, stacked as mini icons in the right bubble.
    var overflowActivities: [IslandActivity] {
        Array(runningActivities.dropFirst(maxActivities))
    }

    /// Everything running, in order, but what's been swiped away.
    private var runningActivities: [IslandActivity] {
        runningActivities(includingHidden: false)
    }

    private func runningActivities(includingHidden: Bool) -> [IslandActivity] {
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
        // A build goes ahead of music, as on the iPhone, where a live
        // activity you're waiting on leads. An agent waiting for your
        // answer goes ahead of everything, even over a full-screen app,
        // since it can't go on without you. A copy leads for its moment, as
        // an alert does, but in an ordinary pill: what it displaces only
        // moves to a bubble, so it takes no more room than a bubble of its
        // own would, and a bubble can be hidden by the front app's menus.
        var running: [IslandActivity] = []
        if claude.needsAnswer {
            running.append(.claudeCode)
        }
        if isShowingAll, clipboard.shown != nil {
            running.append(.clipboard)
        }
        // Mirror was just asked for, and the camera is on while it's open,
        // so it leads, with its green dot in plain sight.
        if isShowingAll, mirror.isOpen {
            running.append(.mirror)
        }
        if isShowingAll, xcode.build != nil {
            running.append(.xcode)
        }
        if isShowingAll, claude.session != nil, !claude.needsAnswer {
            running.append(.claudeCode)
        }
        if isShowingAll, !downloads.downloads.isEmpty {
            running.append(.downloads)
        }
        if isShowingAll, terminal.command != nil {
            running.append(.terminal)
        }
        if isShowingAll, github.activity != nil {
            running.append(.github)
        }
        if isShowingAll, calendar.isShown {
            running.append(.calendar)
        }
        if isShowingAll, reminders.isShown {
            running.append(.reminders)
        }
        if isShowingAll, deviceBatteries.isShown {
            running.append(.deviceBatteries)
        }
        // Files wait just ahead of music. A file dragged near goes ahead
        // of everything, since that's what you're doing right now.
        if isShowingAll, shelf.isShown {
            if shelf.dragPhase != nil {
                running.insert(.shelf, at: 0)
            } else {
                running.append(.shelf)
            }
        }
        if isShowingAll, isNowPlayingShown {
            running.append(.nowPlaying)
        }
        if !includingHidden {
            running.removeAll { hiddenActivities.contains($0) || isInFront($0) }
        }
        if running.count > maxActivities, let promotedActivity,
           let index = running.firstIndex(of: promotedActivity), index > 1 {
            running.insert(running.remove(at: index), at: 1)
        }
        if presentation == .expanded, let expandedActivity, let index = running.firstIndex(of: expandedActivity) {
            running.insert(running.remove(at: index), at: 0)
        }
        return running
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
    /// instead, unless Displays says to keep it there always.
    var isTuckedAway: Bool {
        state == .idle && !hasPhysicalNotch && noNotchVisibility != .always
    }

    /// A small bar at the top edge, marking where the tucked-away island is.
    var showsHandle: Bool {
        isTuckedAway && showsHandleSetting
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
            let idleGrow = isIdleNotchHovered ? Self.hoverGrowth : .zero
            return IslandGeometry(
                size: CGSize(width: notch.width + idleGrow.width, height: notch.height + idleGrow.height),
                cornerRadius: Self.notchCornerRadius,
                isLifted: false
            )
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
            let width = switch primary {
            case .charging?: Self.chargingWidth(notch: notch)
            case .xcode?: XcodeCompactView.width(for: xcode.build, notch: notch)
            case .terminal?: TerminalCompactView.width(for: terminal.command, notch: notch)
            case .calendar?: CalendarCompactView.width(for: calendar, notch: notch)
            case .reminders?: RemindersCompactView.width(for: reminders, notch: notch)
            case .deviceBatteries?: DeviceBatteryCompactView.width(for: deviceBatteries, notch: notch)
            case .shelf?: ShelfCompactView.width(for: shelf, notch: notch)
            case .claudeCode?: Self.compactWidth(notch: notch)
            default: Self.compactWidth(notch: notch)
            }
            return IslandGeometry(
                size: CGSize(width: width + grow.width, height: notch.height + grow.height),
                cornerRadius: Self.compactCornerRadius,
                isLifted: false
            )
        case .expanded:
            let body = switch primary {
            case .nowPlaying?: Self.expandedBodyHeight
            case .xcode?: XcodeExpandedView.bodyHeight(for: xcode.build)
            case .terminal?: TerminalExpandedView.bodyHeight(for: terminal.command)
            case .claudeCode?: ClaudeCodeExpandedView.bodyHeight(for: claude.session)
            case .github?: GitHubExpandedView.bodyHeight(for: github)
            case .downloads?: DownloadExpandedView.bodyHeight(for: downloads)
            case .clipboard?: ClipboardExpandedView.bodyHeight(for: clipboard)
            case .calendar?: CalendarExpandedView.bodyHeight(for: calendar)
            case .reminders?: RemindersExpandedView.bodyHeight(for: reminders)
            case .deviceBatteries?: DeviceBatteryExpandedView.bodyHeight(for: deviceBatteries)
            case .mirror?: MirrorExpandedView.bodyHeight
            case .shelf?: ShelfExpandedView.bodyHeight(for: shelf)
            default: BatteryExpandedView.bodyHeight
            }
            return IslandGeometry(size: CGSize(width: Self.expandedWidth, height: notch.height + body), cornerRadius: Self.expandedCornerRadius, isLifted: true)
        }
    }

    /// The second activity on the right of the pill, as on the iPhone. A
    /// third goes on the left when the front app's menus leave room for it
    /// there, and otherwise joins the second's bubble. When the menus fill
    /// both sides of the notch, there are no bubbles at all, so none covers
    /// a menu; the others keep running and come back once there's room.
    /// Never beside the open island. Any more than three stack up as mini
    /// icons beside the second, always on the right; without room on the
    /// left, the third joins the stack.
    var bubbles: [IslandBubble] {
        guard state == .compact, appMenus?.spillsPastCentre != true else { return [] }
        var trailing = Array(activities.dropFirst())
        guard let second = trailing.first else { return [] }
        let overflow = overflowActivities
        if trailing.count > 1, hasRoomLeftOfIsland(for: bubbleWidth(for: [trailing[1]])) {
            let third = trailing.removeLast()
            return [bubble(on: .trailing, for: [second], stack: overflow), bubble(on: .leading, for: [third])]
        }
        guard !overflow.isEmpty else { return [bubble(on: .trailing, for: trailing)] }
        return [bubble(on: .trailing, for: [second], stack: Array(trailing.dropFirst()) + overflow)]
    }

    /// A lone Now Playing bubble has room for the audio device too.
    private func isWideBubble(for activities: [IslandActivity]) -> Bool {
        activities == [.nowPlaying] && self.activities.count == 2 && audioRoute.route != nil
    }

    private func bubbleWidth(for activities: [IslandActivity]) -> CGFloat {
        if activities.count > 1 {
            Self.pairedBubbleWidth(notch: notchSize)
        } else if isWideBubble(for: activities) {
            Self.wideBubbleWidth(notch: notchSize)
        } else {
            BubbleLayout(notch: notchSize).segmentWidth
        }
    }

    /// Hovering either glyph grows the whole bubble. A stack, even of one,
    /// takes a glyph's place on the outside.
    private func bubble(on side: IslandBubble.Side, for shown: [IslandActivity], stack: [IslandActivity] = []) -> IslandBubble {
        let activities = shown + stack.prefix(1)
        let width = bubbleWidth(for: activities)
        let grow = hovered.map { activities.contains($0) } == true ? Self.bubbleHoverGrowth : 0
        let size = CGSize(width: width + grow, height: notchSize.height + grow)
        let distance = geometry.size.width / 2 + Self.bubbleGap + size.width / 2
        let midX = side == .trailing ? distance : -distance
        let frame = CGRect(x: midX - size.width / 2, y: 0, width: size.width, height: size.height)

        // Split down the middle, so each half opens its own activity.
        let ordered: [IslandActivity] = side == .trailing ? activities : activities.reversed()
        let segmentWidth = frame.width / CGFloat(activities.count)
        let segments = ordered.enumerated().map { index, activity in
            IslandBubble.Segment(
                activity: activity,
                frame: CGRect(x: frame.minX + segmentWidth * CGFloat(index), y: 0, width: segmentWidth, height: frame.height),
                overflow: activity == stack.first ? stack : []
            )
        }
        return IslandBubble(side: side, frame: frame, segments: segments, isWide: isWideBubble(for: activities))
    }

    /// Where the front app's menus reach, as `AppMenuExtent` measured them.
    /// `nil` when there's no telling (Xcode won't say, for one): then
    /// they're taken to be as long as Xcode's.
    var appMenus: AppMenuSpan?

    /// Judged as if the island and the bubble had both grown under the
    /// cursor, so hovering never sends a bubble to the other side.
    private func hasRoomLeftOfIsland(for bubbleWidth: CGFloat) -> Bool {
        let appMenus = appMenus ?? AppMenuSpan(trailingEdge: Self.unmeasuredMenusReach - screenWidth / 2, spillsPastCentre: false)
        let isIslandHovered = hovered != nil && hovered == primaryActivity
        let islandWidth = geometry.size.width + (isIslandHovered ? 0 : Self.hoverGrowth.width)
        let bubbleLeftEdge = -(islandWidth / 2 + Self.bubbleGap + bubbleWidth + Self.bubbleHoverGrowth + IslandShape.earWidth)
        return bubbleLeftEdge >= appMenus.trailingEdge + Self.menuClearance
    }

    // MARK: - Layout constants from the design

    /// Height of the invisible strip along the top edge that brings a
    /// tucked-away island back on screens without a notch.
    static let hoverStripHeight: CGFloat = 5
    /// How far a drag or two fingers go sideways before it counts as a
    /// swipe.
    static let swipeDistance: CGFloat = 36
    /// The hardware notch's bottom corners, by eye: macOS doesn't say. Every
    /// shape uses it, so the pill, the bubbles and the open island all
    /// round off like the notch they grow out of.
    static let notchCornerRadius: CGFloat = 10
    /// The pill and the bubbles beside it.
    static let compactCornerRadius = notchCornerRadius
    /// How much the pill grows under the cursor.
    static let hoverGrowth = CGSize(width: 8, height: 3)
    /// Between the pill and a bubble, as in the design. Each has an 8pt
    /// ear flaring out at the top, so this leaves a clear 2pt even there
    /// and the two read as separate shapes.
    static let bubbleGap: CGFloat = 18
    static let bubbleHoverGrowth: CGFloat = 3
    /// How much wider than the notch is tall each activity's share of a
    /// bubble is, so a ring round its glyph clears the bubble's sides.
    static let bubbleExtraWidth: CGFloat = 6
    /// Left between the front app's last menu and a bubble beside it.
    static let menuClearance: CGFloat = 8
    /// How far from the left edge to take menus no one could measure to
    /// reach: Xcode's, among the longest, end at about 728pt. On a wide
    /// external display that leaves room on the left; on a MacBook it
    /// doesn't.
    static let unmeasuredMenusReach: CGFloat = 740
    /// Between the artwork and the audio device in a wide bubble.
    static let bubbleRouteGap: CGFloat = 6

    /// Two activities' glyphs, each centred in a half as roomy as a
    /// bubble of its own.
    static func pairedBubbleWidth(notch: CGSize) -> CGFloat {
        BubbleLayout(notch: notch).segmentWidth * 2
    }

    /// The artwork and the device, with the same side insets as a bubble
    /// of their own.
    static func wideBubbleWidth(notch: CGSize) -> CGFloat {
        let layout = BubbleLayout(notch: notch)
        return layout.sideInset * 2 + layout.artSize * 2 + bubbleRouteGap
    }
    static let expandedWidth: CGFloat = 420
    static let expandedCornerRadius = notchCornerRadius
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
    static let alertCornerRadius = notchCornerRadius

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
        let isStacked = bubbles.flatMap(\.segments).contains { $0.activity == activity && !$0.overflow.isEmpty }
        if isStacked || overflowActivities.contains(activity) {
            promotedActivity = activity
        }
        // Files moved or deleted since are found again, or leave, and with
        // none left there's nothing to open.
        if activity == .shelf, shelf.dragPhase == nil {
            shelf.refresh()
            guard shelf.isShown else { return }
        }
        collapseTask?.cancel()
        alertTask?.cancel()
        hoverOpenTask?.cancel()
        // A tap on the trackpad as it opens, not again for a switch
        // between activities while it's open.
        if presentation != .expanded, hasTrackpadFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        expandedActivity = activity
        presentation = .expanded
    }

    /// Opens what's under the cursor, straight away or after a pause, when
    /// General says the notch opens on hover.
    private func openOnHoverIfNeeded() {
        hoverOpenTask?.cancel()
        guard presentation == .compact, let activity = hovered else { return }
        switch opening {
        case .whenClicked:
            break
        case .hovered:
            expand(activity)
        case .shortPause:
            hoverOpenTask = Task { [weak self] in
                try? await Task.sleep(for: NotchSettings.openingPause)
                guard !Task.isCancelled, let self, self.presentation == .compact, let hovered = self.hovered else { return }
                self.expand(hovered)
            }
        }
    }

    /// A swipe on the pill or a bubble, or on the notch with nothing
    /// showing, `nil` then. In toward the camera tucks that activity
    /// away, as on the iPhone; out from it brings back the last one
    /// tucked away. Only while closed, and never the lock screen, a
    /// battery alert or an agent waiting for your answer.
    func swipe(_ activity: IslandActivity?, inward: Bool) {
        // Behind a full-screen app nothing shows, so everything would look
        // ended and come back.
        guard state != .expanded, !isFullScreenActive || isRevealedByHover else { return }
        let running = runningActivities(includingHidden: true)
        // Ones that have since ended have nothing to come back to.
        hiddenActivities.removeAll { !running.contains($0) }
        if inward {
            guard let activity, canHide(activity), running.contains(activity) else { return }
            hiddenActivities.removeAll { $0 == activity }
            hiddenActivities.append(activity)
            if promotedActivity == activity {
                promotedActivity = nil
            }
            if hovered == activity {
                setHovering(nil)
            }
        } else if !hiddenActivities.isEmpty {
            hiddenActivities.removeLast()
        }
    }

    private func canHide(_ activity: IslandActivity) -> Bool {
        switch activity {
        // The camera's on while it shows, so its dot stays in sight.
        case .signIn, .charging, .lowBattery, .mirror: false
        case .claudeCode: !claude.needsAnswer
        case .shelf: shelf.dragPhase == nil
        case .xcode, .terminal, .github, .downloads, .clipboard, .calendar, .reminders, .deviceBatteries, .nowPlaying: true
        }
    }

    /// Whether what the activity comes from is in front: Xcode, Calendar,
    /// Reminders, the app playing, or the terminal tab a command or Claude
    /// Code runs in. Any tab of that terminal when it can't say which. An
    /// agent waiting for your answer stays, since its buttons answer it.
    private func isInFront(_ activity: IslandActivity) -> Bool {
        guard let front = frontApp, let frontID = front.bundleIdentifier else { return false }
        func isFront(_ app: String?, tty: String?) -> Bool {
            guard app == frontID else { return false }
            guard let tty, let frontTTY = front.tty else { return true }
            return tty == frontTTY
        }
        switch activity {
        case .xcode: return frontID == XcodeScripting.bundleIdentifier
        case .terminal: return isFront(terminal.command?.appBundleIdentifier, tty: terminal.command?.tty)
        case .claudeCode: return !claude.needsAnswer && isFront(claude.session?.appBundleIdentifier, tty: claude.session?.tty)
        case .nowPlaying: return frontID == nowPlaying.track?.bundleIdentifier
        case .calendar: return frontID == CalendarMonitor.appBundleIdentifier
        case .reminders: return frontID == RemindersMonitor.appBundleIdentifier
        case .github, .downloads, .clipboard, .deviceBatteries, .mirror, .shelf, .signIn, .charging, .lowBattery: return false
        }
    }

    /// Whether a command or Claude Code runs in the app in front with a
    /// known tab, so it's worth asking which tab is in front.
    var wantsFrontTab: Bool {
        guard let frontID = frontApp?.bundleIdentifier else { return false }
        return (terminal.command?.appBundleIdentifier == frontID && terminal.command?.tty != nil)
            || (claude.session?.appBundleIdentifier == frontID && claude.session?.tty != nil)
    }

    /// Something new to show brings a tucked-away activity back.
    private func unhide(_ activity: IslandActivity) {
        hiddenActivities.removeAll { $0 == activity }
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
            // A failure that opened by itself stays open while the cursor
            // is on it, then closes like anything else.
            failureCollapseTask?.cancel()
            openOnHoverIfNeeded()
        } else {
            hoverOpenTask?.cancel()
        }
        if !isHovering, presentation == .compact {
            scheduleAlertDismissal(after: .seconds(1.2))
            terminal.leaveIfDue(after: .seconds(1.2))
            github.leaveIfDue(after: .seconds(1.2))
            downloads.leaveIfDue(after: .seconds(1.2))
            clipboard.leaveIfDue(after: .seconds(1.2))
            calendar.leaveIfDue(after: .seconds(1.2))
            reminders.leaveIfDue(after: .seconds(1.2))
            deviceBatteries.leaveIfDue(after: .seconds(1.2))
        }
    }

    func setIdleNotchHovered(_ isHovered: Bool) {
        guard isHovered != isIdleNotchHovered else { return }
        isIdleNotchHovered = isHovered
    }

    /// Entering full screen closes the player too, so it doesn't come back
    /// expanded when you leave.
    func setFullScreenActive(_ active: Bool) {
        guard active != isFrontAppFullScreen else { return }
        let wasActive = isFullScreenActive
        isFrontAppFullScreen = active
        if isFullScreenActive, !wasActive {
            fullScreenBecameActive()
        }
    }

    private func fullScreenBecameActive() {
        collapseTask?.cancel()
        presentation = .compact
        isRevealedByHover = false
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
            // No camera behind the lock screen.
            mirror.close()
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

    /// A failed build, test run or crash opens by itself. Every result
    /// stays, as the pill once closed, until it's dismissed or the next
    /// build starts.
    private func xcodeEvent(_ event: XcodeBuildMonitor.Event) {
        switch event {
        case .started: activityStarted(.xcode)
        case .failed: activityFailed(.xcode)
        case .succeeded: break
        case .ended: activityEnded(.xcode)
        }
    }

    /// A failed command opens by itself, as a build does.
    private func terminalEvent(_ event: TerminalCommandMonitor.Event) {
        switch event {
        case .started: activityStarted(.terminal)
        case .failed: activityFailed(.terminal)
        case .finished: break
        case .ended: activityEnded(.terminal)
        }
    }

    /// A failed check opens by itself, as a failed build does. Passing,
    /// ready to merge and review requests just show.
    private func githubEvent(_ event: GitHubMonitor.Event) {
        switch event {
        case .started: activityStarted(.github)
        case .failed: activityFailed(.github)
        case .ended: activityEnded(.github)
        }
    }

    /// A permission request, question or plan opens the island and keeps
    /// it open until it's answered, here or in the terminal.
    private func claudeEvent(_ event: ClaudeCodeMonitor.Event) {
        switch event {
        case .started: activityStarted(.claudeCode)
        case .needsAnswer: activityNeedsAnswer(.claudeCode)
        case .answered: activityAnswered(.claudeCode)
        case .finished: break
        case .ended: activityEnded(.claudeCode)
        }
    }

    /// Downloads never open by themselves: the ring fills, then a check
    /// shows for a moment and leaves.
    private func downloadsEvent(_ event: DownloadMonitor.Event) {
        switch event {
        case .started: activityStarted(.downloads)
        case .finished: break
        case .ended: activityEnded(.downloads)
        }
    }

    /// A new copy closes the history, unless the cursor is on it.
    private func clipboardEvent(_ event: ClipboardMonitor.Event) {
        switch event {
        case .copied: activityStarted(.clipboard)
        case .ended: activityEnded(.clipboard)
        }
    }

    /// Time to leave, and a meeting starting, open by themselves, as a
    /// failure does. The rest just shows.
    private func calendarEvent(_ event: CalendarMonitor.Event) {
        switch event {
        case .started: activityStarted(.calendar)
        case .needsYou: activityFailed(.calendar)
        case .ended: activityEnded(.calendar)
        }
    }

    /// A reminder coming due just shows, beside the notch: Reminders says
    /// so itself too.
    private func remindersEvent(_ event: RemindersMonitor.Event) {
        switch event {
        case .started: activityStarted(.reminders)
        case .ended: activityEnded(.reminders)
        }
    }

    /// A device running low, connecting or charging just shows, beside the
    /// notch.
    private func deviceBatteriesEvent(_ event: DeviceBatteryMonitor.Event) {
        switch event {
        case .started: activityStarted(.deviceBatteries)
        case .ended: activityEnded(.deviceBatteries)
        }
    }

    /// From Settings › Activities: every device's battery, opened and then
    /// closed the way the clipboard history is.
    func showDeviceBatteries() {
        guard !isSigningIn, batteryAlert == nil else { return }
        deviceBatteries.showList()
        unhide(.deviceBatteries)
        collapseTask?.cancel()
        failureCollapseTask?.cancel()
        expandedActivity = .deviceBatteries
        presentation = .expanded
        failureCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureOpenDuration)
            guard !Task.isCancelled, let self, !self.isHovering,
                  self.presentation == .expanded, self.expandedActivity == .deviceBatteries else { return }
            self.presentation = .compact
            self.deviceBatteries.leaveIfDue(after: .seconds(1.2))
        }
    }

    /// Opened from its button, or closed by itself.
    private func mirrorEvent(_ event: MirrorCamera.Event) {
        switch event {
        case .started: activityStarted(.mirror)
        case .ended: activityEnded(.mirror)
        }
    }

    /// From a meeting as it starts, or from Settings: turns the camera on
    /// and opens it, over whatever else is open. Opened from Settings, with
    /// the cursor elsewhere, it shrinks to the pill after a while; the
    /// camera then turns off once it has been out of sight a minute.
    func showMirror() {
        guard !isSigningIn, batteryAlert == nil else { return }
        mirror.open()
        collapseTask?.cancel()
        failureCollapseTask?.cancel()
        hoverOpenTask?.cancel()
        expandedActivity = .mirror
        presentation = .expanded
        failureCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mirrorOpenDuration)
            guard !Task.isCancelled, let self, !self.isHovering,
                  self.presentation == .expanded, self.expandedActivity == .mirror else { return }
            self.presentation = .compact
        }
    }

    /// Long enough to look yourself over without the cursor on it.
    private static let mirrorOpenDuration: Duration = .seconds(30)

    /// From Settings › Activities: the rest of the day, opened and then
    /// closed the way the clipboard history is.
    func showTodayEvents() {
        guard !isSigningIn, batteryAlert == nil else { return }
        calendar.showToday()
        collapseTask?.cancel()
        failureCollapseTask?.cancel()
        expandedActivity = .calendar
        presentation = .expanded
        failureCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureOpenDuration)
            guard !Task.isCancelled, let self, !self.isHovering,
                  self.presentation == .expanded, self.expandedActivity == .calendar else { return }
            self.presentation = .compact
            self.calendar.leaveIfDue(after: .seconds(1.2))
        }
    }

    /// From Settings › Activities: opens the history over whatever else is
    /// open, then shrinks back to the pill after a while if the cursor
    /// never comes, and leaves.
    func showClipboardHistory() {
        guard !isSigningIn, batteryAlert == nil else { return }
        clipboard.showHistory()
        collapseTask?.cancel()
        failureCollapseTask?.cancel()
        expandedActivity = .clipboard
        presentation = .expanded
        failureCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureOpenDuration)
            guard !Task.isCancelled, let self, !self.isHovering,
                  self.presentation == .expanded, self.expandedActivity == .clipboard else { return }
            self.presentation = .compact
            self.clipboard.leaveIfDue(after: .seconds(1.2))
        }
    }

    /// From Settings › Activities: opens the shelf, then shrinks back to
    /// the pill after a while if the cursor never comes.
    func showShelf() {
        guard !isSigningIn, batteryAlert == nil, shelf.isShown else { return }
        unhide(.shelf)
        expand(.shelf)
        failureCollapseTask?.cancel()
        failureCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureOpenDuration)
            guard !Task.isCancelled, let self, !self.isHovering,
                  self.presentation == .expanded, self.expandedActivity == .shelf else { return }
            self.presentation = .compact
        }
    }

    // MARK: - Dragging files to the notch

    /// Whether a file drag near the notch should open it to take the files:
    /// not while it's showing the lock screen or a battery alert, nor
    /// stepping aside for a full-screen app.
    var acceptsFileDrops: Bool {
        shelf.isEnabled && !isSigningIn && batteryAlert == nil && (!isFullScreenActive || isRevealedByHover)
    }

    /// From the window controller as a file drag moves. Near the notch, the
    /// pill says Drop; over it, it opens to the places to drop; moving
    /// away again closes it.
    func fileDragMoved(near: Bool, over: Bool) {
        guard acceptsFileDrops else { return }
        let phase: FileShelf.DragPhase? = over ? .over : near ? .near : nil
        guard phase != shelf.dragPhase else { return }
        let wasOver = shelf.dragPhase == .over
        shelf.setDragPhase(phase)
        if phase != nil {
            unhide(.shelf)
        }
        if phase == .over {
            failureCollapseTask?.cancel()
            expand(.shelf)
        } else if wasOver, presentation == .expanded, expandedActivity == .shelf {
            presentation = .compact
        }
    }

    /// Let go, or given up. Dropped on the shelf, the notch stays open on
    /// the files for a moment, until the cursor leaves.
    func fileDragEnded(keepOpen: Bool) {
        guard shelf.dragPhase != nil else { return }
        shelf.endDrag()
        guard presentation == .expanded, expandedActivity == .shelf else { return }
        failureCollapseTask?.cancel()
        guard keepOpen else {
            presentation = .compact
            return
        }
        failureCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dropOpenDuration)
            guard !Task.isCancelled, let self, !self.isHovering,
                  self.presentation == .expanded, self.expandedActivity == .shelf else { return }
            self.presentation = .compact
        }
    }

    /// Files let go over the notch, onto the shelf or sent with AirDrop.
    /// A promised file was saved by MacCove, so it's kept on the shelf even
    /// when it's sent: otherwise nothing would ever clear it away.
    func dropFiles(_ urls: [URL], to zone: FileShelf.DropZone, received: Bool = false) {
        if zone == .shelf || received {
            shelf.add(urls, received: received)
        }
        if zone == .airDrop {
            shelf.airDrop(urls)
        }
    }

    private func shelfEvent(_ event: FileShelf.Event) {
        switch event {
        case .added: unhide(.shelf)
        case .emptied: activityEnded(.shelf)
        }
    }

    /// How long the notch stays open on the files just dropped.
    private static let dropOpenDuration: Duration = .seconds(2.5)

    /// Takes over the island, over anything else open, as an incoming call
    /// does on the iPhone. Only the lock screen and a battery alert come
    /// first.
    private func activityNeedsAnswer(_ activity: IslandActivity) {
        unhide(activity)
        guard !isSigningIn, batteryAlert == nil else { return }
        collapseTask?.cancel()
        failureCollapseTask?.cancel()
        expandedActivity = activity
        presentation = .expanded
    }

    /// Answered: closes again, unless the cursor is on it.
    private func activityAnswered(_ activity: IslandActivity) {
        guard expandedActivity == activity, presentation == .expanded, !isHovering else { return }
        presentation = .compact
    }

    /// Something waiting for an answer stays open when the cursor leaves.
    private var isWaitingForAnswer: Bool {
        presentation == .expanded && expandedActivity == .claudeCode && claude.needsAnswer
    }

    /// A failure left open gives way to whatever its activity starts next,
    /// unless the cursor is on it.
    private func activityStarted(_ activity: IslandActivity) {
        unhide(activity)
        promotedActivity = nil
        guard expandedActivity == activity else { return }
        failureCollapseTask?.cancel()
        if presentation == .expanded, !isHovering {
            presentation = .compact
        }
    }

    /// Opens by itself, unless another activity is open or the island is
    /// keeping out of the way, then shrinks back to the pill after a while
    /// if the cursor never comes.
    private func activityFailed(_ activity: IslandActivity) {
        unhide(activity)
        let isShowingAll = !isFullScreenActive || isRevealedByHover
        let isOtherOpen = presentation == .expanded && expandedActivity != activity
        guard !isSigningIn, batteryAlert == nil, isShowingAll, !isOtherOpen else { return }
        collapseTask?.cancel()
        failureCollapseTask?.cancel()
        expandedActivity = activity
        presentation = .expanded
        failureCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureOpenDuration)
            guard !Task.isCancelled, let self, !self.isHovering,
                  self.presentation == .expanded, self.expandedActivity == activity else { return }
            self.presentation = .compact
        }
    }

    /// Dismissed from its own buttons: nothing is left to keep open.
    private func activityEnded(_ activity: IslandActivity) {
        unhide(activity)
        guard expandedActivity == activity else { return }
        failureCollapseTask?.cancel()
        collapseTask?.cancel()
        presentation = .compact
        expandedActivity = nil
    }

    /// How long a failure stays open by itself before shrinking to the pill.
    private static let failureOpenDuration: Duration = .seconds(8)

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
            guard !Task.isCancelled, let self, !self.isHovering, !self.isWaitingForAnswer,
                  self.shelf.dragPhase != .over else { return }
            self.presentation = .compact
            self.isRevealedByHover = false
            self.scheduleAlertDismissal(after: .seconds(1.2))
            self.terminal.leaveIfDue(after: .seconds(1.2))
            self.github.leaveIfDue(after: .seconds(1.2))
            self.downloads.leaveIfDue(after: .seconds(1.2))
            self.clipboard.leaveIfDue(after: .seconds(1.2))
            self.calendar.leaveIfDue(after: .seconds(1.2))
            self.reminders.leaveIfDue(after: .seconds(1.2))
            self.deviceBatteries.leaveIfDue(after: .seconds(1.2))
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

/// Inside a bubble beside the island, which is as tall as the notch. Each
/// activity gets a share a little wider than that, with its glyph, or the
/// ring round it, scaled to fit.
struct BubbleLayout {
    let segmentWidth: CGFloat
    /// The same as the pill's artwork.
    let artSize: CGFloat
    let sideInset: CGFloat
    let ringDiameter: CGFloat
    let ringLineWidth: CGFloat

    init(notch: CGSize) {
        segmentWidth = notch.height + NotchViewModel.bubbleExtraWidth
        artSize = CompactLayout(notch: notch).artSize
        sideInset = (segmentWidth - artSize) / 2
        // 30pt beside a 37pt notch, leaving a few points above and below.
        ringDiameter = (notch.height * 0.8).rounded()
        // To the nearest half point: 2.5 beside a 37pt notch.
        ringLineWidth = (ringDiameter * 0.18).rounded() / 2
    }
}
