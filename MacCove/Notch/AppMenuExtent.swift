import AppKit
import ApplicationServices

/// Where the front app's menus reach, from the island's centre line.
nonisolated struct AppMenuSpan: Sendable, Equatable {
    /// The right edge of the last menu left of the centre line, so
    /// negative. Xcode's run right up to the notch.
    let trailingEdge: CGFloat
    /// Some menus didn't fit left of the notch, and macOS moved them to its
    /// right, where the bubbles would go.
    let spillsPastCentre: Bool
}

/// How far the front app's menus reach along the menu bar, so bubbles can
/// stay clear of them.
///
/// Only Accessibility can say where another app's menus are, and macOS
/// gives no way to hide or move them, so without the permission there's
/// no telling and the caller keeps the left side clear.
nonisolated enum AppMenuExtent {
    /// Long enough for an app that's busy, short enough that a hung one
    /// doesn't hold up the island.
    private static let timeout: Float = 0.25

    static var isAllowed: Bool {
        AXIsProcessTrusted()
    }

    /// Shows macOS's own prompt, which offers to open the Accessibility
    /// settings.
    static func requestPermission() {
        // The value of `kAXTrustedCheckOptionPrompt`, which Swift 6 won't
        // read here since it's imported as a mutable global.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// The menus of the app with `pid` on the main display's menu bar.
    /// `nil` without the permission, or when its menus are on another
    /// display.
    @concurrent
    static func span(of pid: pid_t, mainDisplayFrame: CGRect, menuBarHeight: CGFloat) async -> AppMenuSpan? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let menuBar: AXUIElement = value(of: kAXMenuBarAttribute, in: app),
              let items: [AXUIElement] = value(of: kAXChildrenAttribute, in: menuBar) else { return nil }

        // Accessibility counts from the main display's top-left corner.
        let centre = mainDisplayFrame.width / 2
        let frames = items.compactMap { item -> CGRect? in
            guard let frame = frame(of: item),
                  frame.width > 0,
                  frame.minY >= 0, frame.minY < menuBarHeight,
                  frame.minX >= 0, frame.minX < mainDisplayFrame.width else { return nil }
            return frame
        }
        guard !frames.isEmpty else { return nil }
        let left = frames.filter { $0.midX < centre }
        return AppMenuSpan(
            trailingEdge: (left.map(\.maxX).max() ?? 0) - centre,
            spillsPastCentre: frames.contains { $0.midX >= centre }
        )
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(of: kAXPositionAttribute, in: element),
              let size: AXValue = value(of: kAXSizeAttribute, in: element) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func value<T>(of attribute: String, in element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
