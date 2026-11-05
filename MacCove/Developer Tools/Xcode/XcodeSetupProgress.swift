//
//  XcodeSetupProgress.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import Observation

/// How far Xcode's Behaviors are set up, from what MacCove has actually
/// heard: each event counts as working the first time Xcode runs its
/// script, and stays counted. Connect Xcode, the guide in the notch and
/// Settings › Developer Tools all read it, so a half-done setup is easy to
/// see and finish.
@Observable
final class XcodeSetupProgress {
    static let shared = XcodeSetupProgress()

    /// The events Xcode has run a script for, kept across launches.
    static let seenKey = "XcodeBehaviorsSeen"

    private(set) var seen = Set(UserDefaults.standard.stringArray(forKey: XcodeSetupProgress.seenKey) ?? [])
    /// Whether MacCove may control Xcode, for the scheme's name and Stop,
    /// Run and Test Again. Not Asked whenever Xcode is closed, since only
    /// an open app can say.
    private(set) var control: OnboardingAccess = .notAsked
    private(set) var isXcodeOpen = AutomationPermission.isRunning(XcodeScripting.bundleIdentifier)

    /// Hands the steps to the notch, from Connect Xcode. Given by
    /// `AppDelegate`, which has the monitor.
    @ObservationIgnored var guideInNotch: () -> Void = {}
    /// Settings, from the guide once it's done.
    @ObservationIgnored var showSettings: () -> Void = {}

    var total: Int {
        XcodeBehaviorScripts.scripts.count
    }

    var count: Int {
        XcodeBehaviorScripts.scripts.filter { seen.contains($0.event) }.count
    }

    var isComplete: Bool {
        count == total
    }

    func isWorking(_ script: XcodeBehaviorScripts.Script) -> Bool {
        seen.contains(script.event)
    }

    func isGroupComplete(_ group: String) -> Bool {
        XcodeBehaviorScripts.scripts(in: group).allSatisfy(isWorking)
    }

    /// Returns whether it's the first time this event's been heard.
    @discardableResult
    func record(_ event: String) -> Bool {
        guard XcodeBehaviorScripts.scripts.contains(where: { $0.event == event }),
              !seen.contains(event) else { return false }
        seen.insert(event)
        UserDefaults.standard.set(Array(seen).sorted(), forKey: Self.seenKey)
        return true
    }

    // MARK: - Controlling Xcode

    func refreshControl() async {
        let id = XcodeScripting.bundleIdentifier
        isXcodeOpen = AutomationPermission.isRunning(id)
        let control = await AutomationPermission.status(of: id)
        // Asking stays asking until macOS has its answer.
        if self.control != .asking {
            self.control = control
        }
    }

    /// Brings up macOS's prompt, if Xcode is open to be asked about.
    func askToControl() async {
        control = .asking
        control = await AutomationPermission.request(XcodeScripting.bundleIdentifier, openingHidden: false)
        isXcodeOpen = AutomationPermission.isRunning(XcodeScripting.bundleIdentifier)
    }

    // MARK: - Text

    /// "Build, Testing › Starts": the groups that are done, then what's
    /// working in the ones that aren't.
    var summary: String {
        XcodeBehaviorScripts.groups.compactMap { group -> String? in
            let working = XcodeBehaviorScripts.scripts(in: group).filter(isWorking)
            if working.isEmpty { return nil }
            if isGroupComplete(group) { return group }
            return "\(group) › " + working.map(\.behavior).formatted(.list(type: .and))
        }
        .joined(separator: ", ")
    }
}
