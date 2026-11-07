//
//  NotchPanel.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit
import SwiftUI

/// A transparent, non-activating panel pinned above the menu bar that hosts
/// the island. It never takes focus, so using the island doesn't pull
/// keyboard focus away from the frontmost app.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Clicks pass through until the cursor is over the island itself.
        ignoresMouseEvents = true
        // Transient: macOS hides it while Mission Control or App Exposé is
        // up, in step with them, and puts it back when you return.
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit nudges windows to keep them clear of the menu bar. The island
    /// has to sit exactly flush with the top edge, over the menu bar, so
    /// take the frame as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets the first click on the island act immediately, even though the panel
/// is never key, and takes files dropped on the notch.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Only the panel you use has one; the lock screen's copy takes no drops.
    var dropTarget: ShelfDropTarget? {
        didSet {
            if dropTarget != nil {
                registerForDraggedTypes(ShelfDropTarget.draggedTypes)
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.entered(sender, in: self) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.updated(sender, in: self) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.exited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.perform(sender) ?? false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget?.ended()
    }
}
