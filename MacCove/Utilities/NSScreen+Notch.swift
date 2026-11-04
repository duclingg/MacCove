//
//  NSScreen+Notch.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit

extension NSScreen {
    /// The display chosen as main in System Settings › Displays, the one
    /// with the menu bar. Unlike `NSScreen.main`, this doesn't follow the
    /// key window between displays.
    static var primary: NSScreen? {
        screens.first
    }

    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// The display's ID, which stays the same while it's connected; the
    /// `NSScreen` itself can be replaced when displays change.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The Mac's own display, rather than one plugged in.
    var isBuiltIn: Bool {
        displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    /// The display the pointer is on.
    static var withPointer: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// The middle of the island on screens without a notch. There's no camera
    /// to hide, so it only needs to separate the artwork from the meter,
    /// not span the real notch's 186pt.
    static let virtualNotchWidth: CGFloat = 100

    /// Size of the camera housing in points. Screens without one, including
    /// an external display used with the lid closed, get a narrow virtual
    /// notch the height of the menu bar.
    var notchSize: CGSize {
        guard hasNotch,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            let menuBarHeight = frame.maxY - visibleFrame.maxY
            return CGSize(width: Self.virtualNotchWidth, height: max(menuBarHeight, 24))
        }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }
}
