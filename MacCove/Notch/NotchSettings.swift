//
//  NotchSettings.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

/// The notch's settings in General and Displays, kept in UserDefaults: the
/// panes write them, and `NotchViewModel`, `NotchWindowController` and
/// `MacCoveApp` read them.
enum NotchSettings {
    /// When the notch opens to an activity's details.
    enum Opening: String, CaseIterable {
        case hovered
        case shortPause
        case whenClicked

        var title: String {
            switch self {
            case .hovered: "When hovered"
            case .shortPause: "After a short pause"
            case .whenClicked: "Only when clicked"
            }
        }
    }

    /// On a display without a notch, there's no camera housing for an idle
    /// island to hide behind.
    enum NoNotchVisibility: String, CaseIterable {
        /// Slides down when something starts, and up out of sight when
        /// nothing's left.
        case duringActivities
        /// A black pill stays at the top edge.
        case always
        /// Nothing shows on a display without a notch.
        case never

        var title: String {
            switch self {
            case .duringActivities: "Only during activities"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    /// Which display the notch shows on.
    enum ActivityDisplay: String, CaseIterable {
        /// The main display in System Settings › Displays.
        case menuBar
        /// Whichever display you're using: it moves to the one with the
        /// pointer.
        case pointer
        /// The Mac's own display, or the one with the menu bar while it's
        /// closed.
        case builtIn

        var title: String {
            switch self {
            case .menuBar: "Display with the menu bar"
            case .pointer: "Display with the pointer"
            case .builtIn: "Built-in display only"
            }
        }
    }

    static let showInMenuBarKey = "ShowInMenuBar"
    static let openingKey = "NotchOpens"
    static let trackpadFeedbackKey = "TrackpadFeedback"
    static let hideInFullScreenKey = "HideInFullScreen"
    static let maxActivitiesKey = "MaxNotchActivities"
    static let noNotchVisibilityKey = "NoNotchDisplaysShow"
    static let showsHandleKey = "NoNotchDisplaysShowHandle"
    static let activityDisplayKey = "ActivitiesDisplay"

    static let defaultOpening = Opening.whenClicked
    static let defaultNoNotchVisibility = NoNotchVisibility.duringActivities
    static let defaultActivityDisplay = ActivityDisplay.menuBar
    /// One in the notch and two in bubbles, at most; the rest stack up as
    /// mini icons in the right bubble.
    static let maxActivitiesOptions = [3, 2, 1]
    static let defaultMaxActivities = 3
    /// How long the cursor rests on the notch before it opens, for After a
    /// Short Pause.
    static let openingPause: Duration = .milliseconds(400)

    static var showsInMenuBar: Bool {
        bool(showInMenuBarKey, default: true)
    }

    static var opening: Opening {
        UserDefaults.standard.string(forKey: openingKey).flatMap(Opening.init) ?? defaultOpening
    }

    static var hasTrackpadFeedback: Bool {
        bool(trackpadFeedbackKey, default: true)
    }

    static var hidesInFullScreen: Bool {
        bool(hideInFullScreenKey, default: true)
    }

    static var maxActivities: Int {
        let stored = UserDefaults.standard.integer(forKey: maxActivitiesKey)
        return maxActivitiesOptions.contains(stored) ? stored : defaultMaxActivities
    }

    static var noNotchVisibility: NoNotchVisibility {
        UserDefaults.standard.string(forKey: noNotchVisibilityKey).flatMap(NoNotchVisibility.init) ?? defaultNoNotchVisibility
    }

    /// A small bar at the top edge where a tucked-away island is.
    static var showsHandle: Bool {
        bool(showsHandleKey, default: false)
    }

    static var activityDisplay: ActivityDisplay {
        UserDefaults.standard.string(forKey: activityDisplayKey).flatMap(ActivityDisplay.init) ?? defaultActivityDisplay
    }

    /// Where the notch goes now, for `activityDisplay`.
    @MainActor static var screen: NSScreen? {
        switch activityDisplay {
        case .menuBar: NSScreen.primary
        case .pointer: NSScreen.withPointer ?? NSScreen.primary
        case .builtIn: NSScreen.screens.first(where: \.isBuiltIn) ?? NSScreen.primary
        }
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
