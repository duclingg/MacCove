//
//  FullScreenDetector.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit
import CoreGraphics

/// Tells whether the app in front is full screen on the main display, so the
/// island can step aside like the iPhone's does.
///
/// macOS doesn't announce other apps' full screen, so this looks at their
/// windows: their owner, layer and bounds are readable without any
/// permission. Window bounds count from the main display's top-left corner,
/// which is where the island always is.
enum FullScreenDetector {
    /// `nil` when MacCove itself is in front (its menu is open), so the
    /// caller keeps whatever it last knew.
    static func isFrontmostAppFullScreen(on screen: NSScreen) -> Bool? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }

        let size = screen.frame.size
        let notchHeight = screen.safeAreaInsets.top
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))

        let appWindows = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let menuBarIsVisible = windows.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == menuBarLevel,
                  let bounds = bounds(of: window) else { return false }
            return bounds.minY == 0 && bounds.width >= size.width
        }

        return appWindows.contains { window in
            guard let bounds = bounds(of: window) else { return false }
            let spansDisplay = bounds.minX == 0 && bounds.width == size.width && bounds.maxY == size.height
            guard spansDisplay else { return false }
            // Covering the whole display, menu bar area included.
            if bounds.minY == 0 { return true }
            // On a notched display, full-screen windows usually stop below the
            // camera. A zoomed window with the Dock hidden has the same shape,
            // so also require the menu bar to be hidden, as it is in full screen.
            return notchHeight > 0 && abs(bounds.minY - notchHeight) < 1 && !menuBarIsVisible
        }
    }

    private static func bounds(of window: [String: Any]) -> CGRect? {
        guard let info = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: info as CFDictionary)
    }
}
