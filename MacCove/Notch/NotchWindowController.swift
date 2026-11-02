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
    }

    private func updateMouse() {
        guard let screen, viewModel.state != .idle else {
            setReceivesMouse(false)
            viewModel.setHovering(false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let top = screen.frame.maxY

        let island = viewModel.geometry.size
        let islandFrame = NSRect(x: screen.frame.midX - island.width / 2, y: top - island.height, width: island.width, height: island.height)
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
