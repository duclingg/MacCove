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
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fullScreenCheck: Task<Void, Never>?
    private var menuMeasurement: Task<Void, Never>?
    private var activityCount = 0

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
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
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

        // Going in and out of full screen switches Spaces; switching apps can
        // bring a full-screen one to the front, and brings its own menus.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleFullScreenCheck()
                    self?.measureAppMenus()
                }
            })
        }
        scheduleFullScreenCheck()
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
        guard lockScreenPanel == nil else { return }
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

    private func checkFullScreen() {
        guard let screen, let isFullScreen = FullScreenDetector.isFrontmostAppFullScreen(on: screen) else { return }
        viewModel.setFullScreenActive(isFullScreen)
    }

    private func reposition() {
        guard let screen = NSScreen.primary else { return }
        self.screen = screen
        viewModel.notchSize = screen.notchSize
        viewModel.hasPhysicalNotch = screen.hasNotch
        viewModel.screenWidth = screen.frame.width

        let size = Self.canvasSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        checkFullScreen()
    }

    private func updateMouse() {
        guard let screen else { return }
        let mouse = NSEvent.mouseLocation
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

        // Also reaches 1pt past the edge. Without it, a cursor parked in the
        // topmost row would count as over the strip but not the island, so
        // the island would keep tucking away and coming back.
        let island = viewModel.geometry.size
        let islandFrame = NSRect(x: screen.frame.midX - island.width / 2, y: top - island.height, width: island.width, height: island.height + 1)

        // An idle notch only grows under the cursor. Clicks there still go
        // through, to the menu bar.
        guard viewModel.state != .idle else {
            setReceivesMouse(false)
            viewModel.setHovering(nil)
            viewModel.setIdleNotchHovered(viewModel.hasPhysicalNotch && islandFrame.contains(mouse))
            return
        }
        viewModel.setIdleNotchHovered(false)
        var hovered = islandFrame.contains(mouse) ? viewModel.primaryActivity : nil
        if hovered == nil {
            hovered = viewModel.bubbles.flatMap(\.segments).first { segment in
                let frame = segment.frame
                return NSRect(x: screen.frame.midX + frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height + 1)
                    .contains(mouse)
            }?.activity
        }

        setReceivesMouse(hovered != nil)
        viewModel.setHovering(hovered)
    }

    /// This runs on every mouse move anywhere on screen, so only talk to the
    /// window server when the answer actually changes.
    private func setReceivesMouse(_ receives: Bool) {
        if panel.ignoresMouseEvents == receives {
            panel.ignoresMouseEvents = !receives
        }
    }
}
