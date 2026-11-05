//
//  OnboardingWindowController.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import SwiftUI

/// Shows the welcome card hanging from the notch, over the menu bar like
/// the notch itself, on the display the notch is on. The panel spans the
/// top of that display, so Done can point at the menu bar item, but only
/// the card takes clicks.
final class OnboardingWindowController {
    /// Room below the menu bar for the tallest step with a guide in it,
    /// and its shadow.
    private static let panelHeight: CGFloat = 900
    /// The notch's own level: above the menu bar.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    private let panel = OnboardingPanel()
    private let model: OnboardingModel
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    /// How many of macOS's prompts are up, with the card lowered for them.
    private var askingCount = 0

    /// Folded back into the notch and gone.
    var onClose: () -> Void = {}

    init(model: OnboardingModel) {
        self.model = model
        panel.level = Self.level

        let hostingView = NotchHostingView(rootView: OnboardingView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        model.whileAsking = { [weak self] work in
            self?.runLowered(to: Self.belowPrompts, work)
        }
        model.whileInSystemSettings = { [weak self] work in
            self?.runLowered(to: .normal, work)
        }
        model.locateMenuItem = { [weak self] in
            self?.menuItemPoint()
        }
        model.onFinish = { [weak self] in
            self?.close()
        }
    }

    func show() {
        reposition()
        NSApp.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
        updateMouse()

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged]
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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        // Drops out once it's on screen at the notch's size.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.island) {
                self?.model.isOpen = true
            }
        }
    }

    /// Shown again while it's already up, from Settings.
    func bringForward() {
        focus()
    }

    /// After a macOS prompt is answered, focus goes back to whatever had it
    /// a moment later, so the card takes it again then too.
    private func refocus() {
        focus()
        Task { @MainActor [weak self] in
            for delay in [300, 700] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, self.askingCount == 0, self.model.isOpen else { return }
                if !self.panel.isKeyWindow {
                    self.focus()
                }
            }
        }
    }

    /// In front and in focus after a prompt or System Settings took it:
    /// the key window, with its switches active and Return and Esc going
    /// to it, which a non-activating panel can be without MacCove itself
    /// being active.
    private func focus() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func close() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors = []
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        panel.orderOut(nil)
        onClose()
    }

    /// Along the top of the display the notch is on.
    private func reposition() {
        guard let screen = NotchSettings.screen ?? NSScreen.primary else { return }
        model.setDisplay(notchSize: screen.notchSize, hasNotch: screen.hasNotch)
        let height = min(Self.panelHeight, screen.frame.height)
        panel.setFrame(
            NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height),
            display: true
        )
    }

    /// Only the card takes the mouse; around it, clicks go to whatever's
    /// underneath, the menu bar included.
    private func updateMouse() {
        let card = model.cardFrame
        let frame = panel.frame
        // SwiftUI measures from the top left; the screen from the bottom left.
        let onScreen = NSRect(x: frame.minX + card.minX, y: frame.maxY - card.maxY, width: card.width, height: card.height)
        let receives = model.isOpen && onScreen.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == receives {
            panel.ignoresMouseEvents = !receives
        }
    }

    /// The bottom middle of the menu bar item, in the panel's coordinates,
    /// when it's on this display.
    private func menuItemPoint() -> CGPoint? {
        guard let item = model.menuBarItem.frame else { return nil }
        let frame = panel.frame
        guard item.midX > frame.minX, item.midX < frame.maxX else { return nil }
        return CGPoint(x: item.midX - frame.minX, y: frame.maxY - item.minY)
    }

    /// macOS's permission prompts are its own windows, which the card above
    /// the menu bar could cover. It goes down to the level of other windows
    /// until each is answered.
    /// For macOS's prompts: still above other apps' windows, so it isn't
    /// left behind them, but below the prompt and alerts.
    private static let belowPrompts = NSWindow.Level.floating

    /// Down to `level` while `work` goes on, then back on top and in focus.
    /// For System Settings, an ordinary window, that's `.normal`; for a
    /// prompt, just below it.
    private func runLowered(to level: NSWindow.Level, _ work: @escaping @MainActor () async -> Void) {
        askingCount += 1
        if askingCount == 1 || level.rawValue < panel.level.rawValue {
            panel.level = level
        }
        Task { @MainActor [weak self] in
            await work()
            guard let self else { return }
            self.askingCount -= 1
            if self.askingCount == 0 {
                self.panel.level = Self.level
                self.refocus()
            }
        }
    }
}

/// A borderless panel above the menu bar, as the notch's is, that can take
/// the keyboard for Return and Esc without bringing MacCove forward.
final class OnboardingPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            // Non-activating, so it can take the keyboard, and draw its
            // switches as active, whichever app is in front: macOS doesn't
            // always let MacCove become active again after a prompt or
            // System Settings. Opening System Settings asks to activate
            // MacCove at the click, which is when it needs to be.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Flush with the top edge, over the menu bar, as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
