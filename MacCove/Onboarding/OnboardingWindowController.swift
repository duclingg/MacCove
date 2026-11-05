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
    /// Room below the menu bar for the tallest step and its shadow.
    private static let panelHeight: CGFloat = 640
    /// The notch's own level: above the menu bar.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    private let panel = OnboardingPanel()
    private let model: OnboardingModel
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var restoringLevel: Task<Void, Never>?
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

        model.belowAlerts = { [weak self] waits, body, then in
            self?.runBelowAlerts(waits: waits, body, then: then)
        }
        model.whileAsking = { [weak self] work in
            self?.runWhileAsking(work)
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
        restoringLevel?.cancel()
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
    private func runWhileAsking(_ work: @escaping @MainActor () async -> Void) {
        askingCount += 1
        panel.level = .normal
        Task { @MainActor [weak self] in
            await work()
            guard let self else { return }
            self.askingCount -= 1
            if self.askingCount == 0, self.restoringLevel == nil {
                self.panel.level = Self.level
                self.panel.orderFrontRegardless()
                self.panel.makeKey()
            }
        }
    }

    /// Set Up for Xcode, the terminal and GitHub ask in alerts, which sit
    /// below the menu bar and so below the card. The card goes down to the
    /// level of other windows until the alert's answered.
    private func runBelowAlerts(waits: Bool, _ body: () -> Void, then: @escaping @MainActor () -> Void) {
        restoringLevel?.cancel()
        panel.level = .normal
        body()
        restoringLevel = Task { @MainActor [weak self] in
            if waits {
                // Its alert goes up once it's looked for a sign-in.
                // Up to four seconds.
                for _ in 0..<40 {
                    if NSApp.modalWindow != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                }
            }
            while NSApp.modalWindow != nil {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.restoringLevel = nil
            // First, so a prompt it starts keeps the card lowered.
            then()
            if self.askingCount == 0 {
                self.panel.level = Self.level
                self.panel.orderFrontRegardless()
                self.panel.makeKey()
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
