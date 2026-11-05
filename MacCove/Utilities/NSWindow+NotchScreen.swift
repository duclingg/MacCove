//
//  NSWindow+NotchScreen.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

extension NSWindow {
    /// Centred on the display the notch is on, where the welcome and the
    /// guides are, so a window MacCove opens isn't left on another display.
    /// One already there stays where it was put, unless `always`.
    func centerOnNotchScreen(always: Bool = false) {
        guard let target = NotchSettings.screen ?? NSScreen.primary else {
            center()
            return
        }
        if !always, let current = screen, current.displayID == target.displayID {
            return
        }
        let visible = target.visibleFrame
        // A little above the middle, as `center()` puts it.
        let origin = CGPoint(
            x: (visible.midX - frame.width / 2).rounded(),
            y: (visible.minY + (visible.height - frame.height) * 2 / 3).rounded()
        )
        setFrameOrigin(origin)
    }
}
