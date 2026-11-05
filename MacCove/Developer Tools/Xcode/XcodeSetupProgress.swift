//
//  XcodeSetupProgress.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import Observation

/// How far Xcode's Behaviors are set up: each event counts once Xcode's
/// own settings run MacCove's script for it, read from Xcode's
/// preferences as you set it up. Connect Xcode, the guide in the notch
/// and Settings › Developer Tools all read it, so a half-done setup is
/// easy to see and finish.
@Observable
final class XcodeSetupProgress {
    static let shared = XcodeSetupProgress()

    private static let xcodeDomain = "com.apple.dt.Xcode" as CFString
    /// Behaviors are kept under Xcode's version, "Xcode.AlertEvents.17_0".
    private static let alertEventsPrefix = "Xcode.AlertEvents."

    /// The events whose Behavior runs MacCove's script for that event, as
    /// Xcode's settings have it now.
    private(set) var added: Set<String> = []
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

    init() {
        refreshBehaviors()
    }

    var total: Int {
        XcodeBehaviorScripts.scripts.count
    }

    /// Added in Xcode.
    var count: Int {
        XcodeBehaviorScripts.scripts.filter(isSetUp).count
    }

    var isComplete: Bool {
        count == total
    }

    func isAdded(_ script: XcodeBehaviorScripts.Script) -> Bool {
        added.contains(script.event)
    }

    /// Added in Xcode's settings, which is all that counts.
    func isSetUp(_ script: XcodeBehaviorScripts.Script) -> Bool {
        isAdded(script)
    }

    func isGroupComplete(_ group: String) -> Bool {
        XcodeBehaviorScripts.scripts(in: group).allSatisfy(isSetUp)
    }

    // MARK: - Xcode's settings

    /// Reads Xcode's Behaviors again: each event counts as added when Run
    /// is on and points at MacCove's script with that event's name. Xcode
    /// saves them as they're changed, so this keeps up while you set it
    /// up.
    func refreshBehaviors() {
        CFPreferencesAppSynchronize(Self.xcodeDomain)
        var found: Set<String> = []
        if let events = Self.currentAlertEvents() {
            for script in XcodeBehaviorScripts.scripts {
                guard let event = events["Xcode.AlertEvent.\(script.xcodeEvent)"] as? [String: Any],
                      let runScript = event["Xcode.Alert.RunScript"] as? [String: Any],
                      Self.isEnabled(runScript["enabled"]),
                      let path = runScript["path"] as? String,
                      Self.isMacCoveScript(path, named: script.fileName) else { continue }
                found.insert(script.event)
            }
        }
        if found != added {
            added = found
        }
    }

    /// For Reset All Settings: turns off Run wherever a Behavior runs one
    /// of MacCove's scripts, in every Xcode version's Behaviors, and drops
    /// them from Xcode's recent scripts. Other Behaviors stay as they are.
    static func removeFromXcode() {
        CFPreferencesAppSynchronize(xcodeDomain)
        guard let keys = CFPreferencesCopyKeyList(xcodeDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else {
            return
        }
        for key in keys where key.hasPrefix(alertEventsPrefix) {
            guard var events = CFPreferencesCopyAppValue(key as CFString, xcodeDomain) as? [String: Any] else { continue }
            var changed = false
            for (name, value) in events {
                guard var event = value as? [String: Any],
                      let runScript = event["Xcode.Alert.RunScript"] as? [String: Any],
                      let path = runScript["path"] as? String,
                      isInMacCoveFolder(path) else { continue }
                event["Xcode.Alert.RunScript"] = nil
                events[name] = event.isEmpty ? nil : event
                changed = true
            }
            if changed {
                CFPreferencesSetAppValue(key as CFString, events as NSDictionary, xcodeDomain)
            }
        }
        let recentKey = "Xcode.Alert.Script.Recent" as CFString
        if let recent = CFPreferencesCopyAppValue(recentKey, xcodeDomain) as? [String] {
            let kept = recent.filter { !isInMacCoveFolder($0) }
            if kept.count != recent.count {
                CFPreferencesSetAppValue(recentKey, kept as NSArray, xcodeDomain)
            }
        }
        CFPreferencesAppSynchronize(xcodeDomain)
    }

    /// Anywhere MacCove has kept Xcode's scripts, now or before.
    private static func isInMacCoveFolder(_ path: String) -> Bool {
        let decoded = path.removingPercentEncoding ?? path
        return decoded.contains("/Library/Scripts/MacCove/") || decoded.contains("/Library/Application Support/MacCove/")
    }

    /// The Behaviors of the newest Xcode that has saved any.
    private static func currentAlertEvents() -> [String: Any]? {
        guard let keys = CFPreferencesCopyKeyList(xcodeDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else {
            return nil
        }
        let newest = keys
            .filter { $0.hasPrefix(alertEventsPrefix) }
            .max { version(of: $0).lexicographicallyPrecedes(version(of: $1)) }
        guard let newest else { return nil }
        return CFPreferencesCopyAppValue(newest as CFString, xcodeDomain) as? [String: Any]
    }

    /// "Xcode.AlertEvents.17_0" → [17, 0].
    private static func version(of key: String) -> [Int] {
        key.dropFirst(alertEventsPrefix.count).split(separator: "_").compactMap { Int($0) }
    }

    /// Xcode keeps "1", but a Boolean would mean the same.
    private static func isEnabled(_ value: Any?) -> Bool {
        switch value {
        case let string as String: string == "1" || string.lowercased() == "true"
        case let number as NSNumber: number.boolValue
        default: false
        }
    }

    /// In MacCove's Xcode folder, under the script's name. Xcode may keep
    /// the path percent-encoded.
    private static func isMacCoveScript(_ path: String, named fileName: String) -> Bool {
        let decoded = path.removingPercentEncoding ?? path
        let url = URL(filePath: decoded)
        return url.lastPathComponent == fileName
            && url.deletingLastPathComponent().standardizedFileURL == XcodeBehaviorScripts.directory.standardizedFileURL
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

    /// As Set Up starts: macOS asks to let MacCove control Xcode now,
    /// rather than at the first build. Only an open app can be asked
    /// about, so Xcode opens first if it isn't, as the setup needs it to
    /// be anyway. Answered already, nothing comes up.
    func askToControlAtSetUp() async {
        let id = XcodeScripting.bundleIdentifier
        await refreshControl()
        guard control == .notAsked else { return }
        if !AutomationPermission.isRunning(id) {
            control = .asking
            XcodeCommand.open(workspacePath: nil)
            // Xcode takes a while to open: up to a minute.
            for _ in 0..<120 {
                if AutomationPermission.isRunning(id) { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await askToControl()
    }

    // MARK: - Text

    /// "Build, Testing › Starts": the groups that are done, then what's
    /// set up in the ones that aren't.
    var summary: String {
        XcodeBehaviorScripts.groups.compactMap { group -> String? in
            let setUp = XcodeBehaviorScripts.scripts(in: group).filter(isSetUp)
            if setUp.isEmpty { return nil }
            if isGroupComplete(group) { return group }
            return "\(group) › " + setUp.map(\.behavior).formatted(.list(type: .and))
        }
        .joined(separator: ", ")
    }
}
