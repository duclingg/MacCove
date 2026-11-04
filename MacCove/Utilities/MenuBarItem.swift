//
//  MenuBarItem.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import Observation

/// MacCove's item in the menu bar, with Settings and Quit.
///
/// Whether it shows is the item's own visibility, which macOS keeps and
/// shows in System Settings › Menu Bar. So General's switch, the one in
/// System Settings, and ⌘-dragging the item off the menu bar all change
/// the same thing, and each follows the others.
@Observable
final class MenuBarItem {
    /// What macOS calls the first item an app makes, and so what System
    /// Settings already knows MacCove's by. Keeping it keeps the choice
    /// made there.
    private static let autosaveName = "Item-0"
    /// Where macOS keeps that choice, in MacCove's own defaults. Not
    /// documented, so it's only read to hear about changes made in System
    /// Settings; the item's `isVisible` is what's set.
    private static let visibilityKey = "NSStatusItem VisibleCC \(autosaveName)"

    /// Xcode runs the app to draw SwiftUI previews, which shouldn't add a
    /// menu bar item each time. Previews in JIT mode set the playgrounds
    /// variable instead of the previews one.
    static let isRunningForPreviews = ["XCODE_RUNNING_FOR_PREVIEWS", "XCODE_RUNNING_FOR_PLAYGROUNDS"]
        .contains { ProcessInfo.processInfo.environment[$0] == "1" }

    private(set) var isShown = true

    /// As the menu opens: permissions may have changed since.
    var onOpen: () -> Void {
        get { target.onOpen }
        set { target.onOpen = newValue }
    }
    var showSettings: () -> Void {
        get { target.showSettings }
        set { target.showSettings = newValue }
    }

    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private let target = MenuTarget()
    @ObservationIgnored private var visibilityObservation: NSKeyValueObservation?
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    /// Adds the item, shown or not as it was left.
    func install() {
        guard statusItem == nil, !Self.isRunningForPreviews else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        // ⌘-dragging it off the menu bar hides it, as System Settings does.
        item.behavior = .removalAllowed
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "MacCove")
        item.menu = makeMenu()
        statusItem = item
        adoptOldSetting(item)
        isShown = item.isVisible

        // ⌘-dragged off, or hidden some other way.
        // Not necessarily on the main thread, so it goes there.
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { @Sendable [weak self] _, change in
            guard let shown = change.newValue, let self else { return }
            Task { @MainActor in
                self.visibilityChanged(shown)
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
    }

    /// From General's switch. System Settings follows.
    func setShown(_ shown: Bool) {
        guard let statusItem else { return }
        statusItem.isVisible = shown
        visibilityChanged(shown)
    }

    private func visibilityChanged(_ shown: Bool) {
        if isShown != shown {
            isShown = shown
        }
    }

    /// Changed in System Settings, which writes to MacCove's defaults.
    /// The item is brought into line in case macOS left that to the app.
    private func defaultsChanged() {
        guard let statusItem,
              let shown = UserDefaults.standard.object(forKey: Self.visibilityKey) as? Bool else { return }
        if statusItem.isVisible != shown {
            statusItem.isVisible = shown
        }
        visibilityChanged(shown)
    }

    /// MacCove used to keep its own Show in Menu Bar setting, apart from
    /// macOS's. Hidden there, it's hidden here too, once; then it's gone.
    private func adoptOldSetting(_ item: NSStatusItem) {
        let defaults = UserDefaults.standard
        guard let shown = defaults.object(forKey: NotchSettings.showInMenuBarKey) as? Bool else { return }
        if !shown {
            item.isVisible = false
        }
        defaults.removeObject(forKey: NotchSettings.showInMenuBarKey)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = target

        let settings = NSMenuItem(title: "Settings", action: #selector(MenuTarget.openSettings), keyEquivalent: "")
        settings.target = target
        settings.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacCove", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }
}

/// The menu's actions and delegate, which AppKit calls through
/// Objective-C.
private final class MenuTarget: NSObject, NSMenuDelegate {
    var onOpen: () -> Void = {}
    var showSettings: () -> Void = {}

    @objc func openSettings() {
        showSettings()
    }

    func menuWillOpen(_ menu: NSMenu) {
        onOpen()
    }
}
