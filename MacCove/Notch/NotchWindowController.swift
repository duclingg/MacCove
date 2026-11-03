import AppKit
import SwiftUI

/// Owns the notch panel: keeps it centred on the main display and decides
/// whether the panel should receive the mouse based on where the cursor is
/// relative to the island. Lives for the lifetime of the app.
final class NotchWindowController {
    /// Room for the largest island state plus its shadow.
    private static let canvasSize = CGSize(width: 640, height: 300)

    private let panel = NotchPanel()
    private let viewModel: NotchViewModel
    private var screen: NSScreen?
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fullScreenCheck: Task<Void, Never>?

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
        // bring a full-screen one to the front.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullScreenCheck() }
            })
        }
        scheduleFullScreenCheck()
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

    private func checkFullScreen() {
        guard let screen, let isFullScreen = FullScreenDetector.isFrontmostAppFullScreen(on: screen) else { return }
        viewModel.setFullScreenActive(isFullScreen)
    }

    private func reposition() {
        guard let screen = NSScreen.primary else { return }
        self.screen = screen
        viewModel.notchSize = screen.notchSize
        viewModel.hasPhysicalNotch = screen.hasNotch

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

        guard viewModel.state != .idle else {
            setReceivesMouse(false)
            viewModel.setHovering(false)
            return
        }

        // Also reaches 1pt past the edge. Without it, a cursor parked in the
        // topmost row would count as over the strip but not the island, so
        // the island would keep tucking away and coming back.
        let island = viewModel.geometry.size
        let islandFrame = NSRect(x: screen.frame.midX - island.width / 2, y: top - island.height, width: island.width, height: island.height + 1)
        let isOverIsland = islandFrame.contains(mouse)

        setReceivesMouse(isOverIsland)
        viewModel.setHovering(isOverIsland)
    }

    /// This runs on every mouse move anywhere on screen, so only talk to the
    /// window server when the answer actually changes.
    private func setReceivesMouse(_ receives: Bool) {
        if panel.ignoresMouseEvents == receives {
            panel.ignoresMouseEvents = !receives
        }
    }
}
