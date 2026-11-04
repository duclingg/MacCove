//
//  NotchSettings.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import Foundation

/// The notch's settings in General, kept in UserDefaults: the pane writes
/// them, and `NotchViewModel` and `MacCoveApp` read them.
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

    static let showInMenuBarKey = "ShowInMenuBar"
    static let openingKey = "NotchOpens"
    static let trackpadFeedbackKey = "TrackpadFeedback"
    static let hideInFullScreenKey = "HideInFullScreen"
    static let maxActivitiesKey = "MaxNotchActivities"

    static let defaultOpening = Opening.whenClicked
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

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
