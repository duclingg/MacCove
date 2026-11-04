//
//  NotchWindowController.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit
import os
import SwiftUI

/// Owns the notch panel: keeps it centred on the main display and decides
/// whether the panel should receive the mouse based on where the cursor is
/// relative to the island. Lives for the lifetime of the app.
final class NotchWindowController {
    /// Room for the largest island state plus its shadow.
    private static let canvasSize = CGSize(width: 640, height: 300)

    private let panel = NotchPanel()
    /// A copy of the island above the lock screen, there only while locked.
    /// It's display only: the lock screen's space doesn't pass on clicks, so
    /// the panel you click never goes in it.
    private var lockScreenPanel: NotchPanel?
    private var lockScreenPanelRemoval: Task<Void, Never>?
    private var lockObservers: [NSObjectProtocol] = []
    private let viewModel: NotchViewModel
    private var screen: NSScreen?
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    /// Off on a display without a notch when Displays says Never.
    private var isPanelShown = true
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fullScreenCheck: Task<Void, Never>?
    private var menuMeasurement: Task<Void, Never>?
    private var activityCount = 0
    /// The two-finger swipe under way: where it started, measured from the
    /// notch's centre line, what it started on, and how far it has gone.
    private var scrollSwipe: ScrollSwipe?
    /// Asks Terminal or iTerm which tab is in front while one of them is.
    private var frontTabCheck: Task<Void, Never>?

    private struct ScrollSwipe {
        let activity: IslandActivity?
        let startOffset: CGFloat
        var distanceX: CGFloat = 0
        var distanceY: CGFloat = 0
        var isDone = false
    }

    /// Accessibility is asked for once, the first time a bubble needs a
    /// place; after that it's up to System Settings.
    private static let askedForAccessibilityKey = "AskedForMenuBarAccessibility"
    /// An app that has just come to the front may not have laid out its
    /// menus yet, and Accessibility then reports few or none: measured
    /// again after each of these.
    private static let menuMeasurementDelays: [Duration] = [.milliseconds(150), .milliseconds(500), .seconds(1.5)]
    private static let log = Logger(subsystem: "com.justinhoang.MacCove", category: "AppMenus")

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel

        let hostingView = NotchHostingView(rootView: IslandView(viewModel: viewModel))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        reposition()
        if isPanelShown {
            panel.orderFrontRegardless()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        // Displays' settings: which display, and whether one without a
        // notch shows MacCove at all.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }) {
            eventMonitors.append(local)
        }
        // Two-finger swipes: local while the notch takes the pointer, global
        // over an idle notch, whose clicks and scrolls go to the menu bar.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let scroll = ScrollSample(event)
            MainActor.assumeIsolated { self?.handleScroll(scroll) }
        }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let scroll = ScrollSample(event)
            MainActor.assumeIsolated { self?.handleScroll(scroll) }
            return event
        }) {
            eventMonitors.append(local)
        }

        // Going in and out of full screen switches Spaces; switching apps can
        // bring a full-screen one to the front, and brings its own menus.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleFullScreenCheck()
                    self?.measureAppMenus()
                    self?.frontAppChanged()
                }
            })
        }
        scheduleFullScreenCheck()
        frontAppChanged()
        observeActivityCount()

        // Posted by loginwindow to every app as the screen locks and unlocks.
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLockChanged(locked: locked) }
            })
        }
    }

    private func screenLockChanged(locked: Bool) {
        lockScreenPanelRemoval?.cancel()
        guard locked else {
            // Stays until the lock screen has faded away, so the unlock plays
            // on without a gap; the panel underneath shows the same island.
            lockScreenPanelRemoval = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.lockScreenPanel?.orderOut(nil)
                self.lockScreenPanel = nil
            }
            return
        }
        guard lockScreenPanel == nil, isPanelShown else { return }
        let lockPanel = NotchPanel()
        let hostingView = NotchHostingView(rootView: IslandView(viewModel: viewModel))
        hostingView.sizingOptions = []
        lockPanel.contentView = hostingView
        lockPanel.setFrame(panel.frame, display: true)
        lockPanel.orderFrontRegardless()
        LockScreenSpace.move(lockPanel)
        lockScreenPanel = lockPanel
    }

    /// Checks now, and again once the full-screen animation has had time to
    /// finish and the window covers the display.
    private func scheduleFullScreenCheck() {
        checkFullScreen()
        fullScreenCheck?.cancel()
        fullScreenCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.checkFullScreen()
        }
    }

    /// Bubbles have arrived, or gone.
    private func observeActivityCount() {
        let count = withObservationTracking {
            viewModel.activities.count
        } onChange: {
            Task { @MainActor [weak self] in self?.observeActivityCount() }
        }
        guard count != activityCount else { return }
        activityCount = count
        measureAppMenus()
    }

    /// Where the front app's menus reach, so bubbles stay clear of them.
    /// Only needed once there are bubbles, and only then is Accessibility
    /// asked for.
    private func measureAppMenus() {
        menuMeasurement?.cancel()
        guard let screen, viewModel.activities.count > 1 else { return }
        guard AppMenuExtent.isAllowed else {
            viewModel.appMenus = nil
            if !UserDefaults.standard.bool(forKey: Self.askedForAccessibilityKey) {
                UserDefaults.standard.set(true, forKey: Self.askedForAccessibilityKey)
                AppMenuExtent.requestPermission()
            }
            return
        }
        // MacCove itself is in front while its menu is open; its menus are
        // gone again once it closes, so keep what was known.
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let pid = app.processIdentifier
        let name = app.bundleIdentifier ?? "\(pid)"
        let frame = screen.frame
        let menuBarHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        // Measured each time, as menus can still be filling in at first.
        // Less room than before shows straight away, so no bubble sits on a
        // menu; more room waits for the last measurement, so bubbles don't
        // hop left and back.
        menuMeasurement = Task { [weak self] in
            var settled: AppMenuSpan?
            for delay in Self.menuMeasurementDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                guard let span = await AppMenuExtent.span(of: pid, mainDisplayFrame: frame, menuBarHeight: menuBarHeight) else { continue }
                guard !Task.isCancelled, let self else { return }
                Self.log.debug("\(name, privacy: .public) menus reach \(span.trailingEdge) from centre, past it: \(span.spillsPastCentre)")
                settled = span
                if let current = self.viewModel.appMenus,
                   span.trailingEdge > current.trailingEdge || (span.spillsPastCentre && !current.spillsPastCentre) {
                    self.viewModel.appMenus = span
                }
            }
            guard !Task.isCancelled, let self else { return }
            if settled == nil {
                Self.log.debug("\(name, privacy: .public) menus couldn't be measured")
            }
            self.viewModel.appMenus = settled
        }
    }

    /// An activity leaves the notch while what it comes from is in front.
    /// Switching tabs doesn't switch apps, so while Terminal or iTerm is in
    /// front with a command or Claude Code running in it, which tab is in
    /// front is asked again every so often.
    private func frontAppChanged() {
        frontTabCheck?.cancel()
        let app = NSWorkspace.shared.frontmostApplication
        let id = app?.bundleIdentifier
        viewModel.frontApp = NotchViewModel.FrontApp(bundleIdentifier: id)
        guard let id, TerminalWindow.knowsTabs(id) else { return }
        frontTabCheck = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.viewModel.wantsFrontTab {
                    let tty = TerminalWindow.frontTTY(of: id)
                    if self.viewModel.frontApp?.tty != tty {
                        self.viewModel.frontApp?.tty = tty
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func checkFullScreen() {
        guard let screen, let isFullScreen = FullScreenDetector.isFrontmostAppFullScreen(on: screen) else { return }
        viewModel.setFullScreenActive(isFullScreen)
    }

    /// Onto the display Displays picks, at the top centre, or out of sight
    /// on one without a notch when it says Never. Only does anything when
    /// that's changed, since it runs on every change to the settings.
    private func reposition() {
        guard let screen = NotchSettings.screen else { return }
        let shows = screen.hasNotch || NotchSettings.noNotchVisibility != .never
        if shows != isPanelShown {
            isPanelShown = shows
            if shows {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
                setReceivesMouse(false)
                viewModel.setHovering(nil)
            }
        }

        let size = Self.canvasSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        guard frame != panel.frame || screen.displayID != self.screen?.displayID || screen.notchSize != viewModel.notchSize else { return }
        self.screen = screen
        viewModel.notchSize = screen.notchSize
        viewModel.hasPhysicalNotch = screen.hasNotch
        viewModel.screenWidth = screen.frame.width
        panel.setFrame(frame, display: true)
        checkFullScreen()
        measureAppMenus()
    }

    /// With Display with the pointer, the notch moves to the display the
    /// pointer has moved to, but not while it's open.
    private func followPointerIfNeeded(_ mouse: NSPoint) {
        guard NotchSettings.activityDisplay == .pointer, viewModel.state != .expanded,
              let screen, !NSMouseInRect(mouse, screen.frame, false),
              NSScreen.withPointer != nil else { return }
        reposition()
    }

    private func updateMouse() {
        let mouse = NSEvent.mouseLocation
        followPointerIfNeeded(mouse)
        guard let screen, isPanelShown else { return }
        let top = screen.frame.maxY

        // A tucked-away island comes back when the cursor reaches the strip
        // along the top edge, then is handled like any other hover below.
        if viewModel.canRevealOnHover {
            let width = NotchViewModel.compactWidth(notch: viewModel.notchSize)
            let stripHeight = NotchViewModel.hoverStripHeight
            // Reaches 1pt past the edge so the topmost row of pixels counts.
            let strip = NSRect(x: screen.frame.midX - width / 2, y: top - stripHeight, width: width, height: stripHeight + 1)
            if strip.contains(mouse) {
                viewModel.revealFromHoverStrip()
            }
        }

        // An idle notch only grows under the cursor. Clicks there still go
        // through, to the menu bar.
        guard viewModel.state != .idle else {
            setReceivesMouse(false)
            viewModel.setHovering(nil)
            viewModel.setIdleNotchHovered(viewModel.hasPhysicalNotch && islandFrame(on: screen).contains(mouse))
            return
        }
        viewModel.setIdleNotchHovered(false)
        let hovered = activity(at: mouse, on: screen)
        setReceivesMouse(hovered != nil)
        viewModel.setHovering(hovered)
    }

    /// Reaches 1pt past the top edge. Without it, a cursor parked in the
    /// topmost row would count as over the strip but not the island, so
    /// the island would keep tucking away and coming back.
    private func islandFrame(on screen: NSScreen) -> NSRect {
        let island = viewModel.geometry.size
        return NSRect(x: screen.frame.midX - island.width / 2, y: screen.frame.maxY - island.height, width: island.width, height: island.height + 1)
    }

    /// The pill's activity, or a bubble's, under the cursor.
    private func activity(at mouse: NSPoint, on screen: NSScreen) -> IslandActivity? {
        if islandFrame(on: screen).contains(mouse) {
            return viewModel.primaryActivity
        }
        let top = screen.frame.maxY
        return viewModel.bubbles.flatMap(\.segments).first { segment in
            let frame = segment.frame
            return NSRect(x: screen.frame.midX + frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height + 1)
                .contains(mouse)
        }?.activity
    }

    /// A two-finger swipe across the pill or a bubble, as on the iPhone: in
    /// toward the camera tucks that activity away, out from the notch brings
    /// the last one back. Once per swipe, and only for swipes that start on
    /// the notch, mostly sideways. The momentum after lifting doesn't count.
    private func handleScroll(_ event: ScrollSample) {
        guard let screen, event.isTrackpad, !event.isMomentum else { return }
        if event.began {
            let mouse = NSEvent.mouseLocation
            // With nothing showing, the whole notch is somewhere to swipe
            // out from, even when the island is tucked away above the edge.
            let isOnIdleNotch = viewModel.state == .idle && idleSwipeFrame(on: screen).contains(mouse)
            let target = viewModel.state == .idle ? nil : activity(at: mouse, on: screen)
            scrollSwipe = target != nil || isOnIdleNotch
                ? ScrollSwipe(activity: target, startOffset: mouse.x - screen.frame.midX)
                : nil
        }
        if event.ended {
            scrollSwipe = nil
            return
        }
        guard var swipe = scrollSwipe, !swipe.isDone else { return }
        swipe.distanceX += event.fingersX
        swipe.distanceY += abs(event.deltaY)
        if abs(swipe.distanceX) >= NotchViewModel.swipeDistance, abs(swipe.distanceX) > swipe.distanceY * 1.5 {
            swipe.isDone = true
            // Toward the centre line from where it started.
            let inward = swipe.startOffset == 0 || (swipe.distanceX < 0) == (swipe.startOffset > 0)
            viewModel.swipe(swipe.activity, inward: inward)
        }
        scrollSwipe = swipe
    }

    private func idleSwipeFrame(on screen: NSScreen) -> NSRect {
        let width = NotchViewModel.compactWidth(notch: viewModel.notchSize)
        let height = viewModel.notchSize.height
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height + 1)
    }

    /// This runs on every mouse move anywhere on screen, so only talk to the
    /// window server when the answer actually changes.
    private func setReceivesMouse(_ receives: Bool) {
        if panel.ignoresMouseEvents == receives {
            panel.ignoresMouseEvents = !receives
        }
    }
}

/// What a swipe needs from a scroll event, copied out so it can go to the
/// main actor.
nonisolated private struct ScrollSample: Sendable {
    /// Trackpads and Magic Mice; a wheel's clicks have no phases to follow.
    let isTrackpad: Bool
    /// Still moving after the fingers lifted.
    let isMomentum: Bool
    let began: Bool
    let ended: Bool
    /// Which way the fingers went, right positive. Natural scrolling moves
    /// the content with the fingers; otherwise the deltas run the other way.
    let fingersX: CGFloat
    let deltaY: CGFloat

    init(_ event: NSEvent) {
        isTrackpad = event.hasPreciseScrollingDeltas
        isMomentum = !event.momentumPhase.isEmpty
        began = event.phase.contains(.began)
        ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        fingersX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        deltaY = event.scrollingDeltaY
    }
}
