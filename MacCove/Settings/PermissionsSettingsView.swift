//
//  PermissionsSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import Contacts
import CoreLocation
import EventKit
import ServiceManagement
import SwiftUI

struct PermissionsSettingsView: View {
    // MARK: States
    @State private var permissions: [Permission] = []

    // MARK: View
    var body: some View {
        Form {
            Section {
                ForEach(permissions) { permission in
                    permissionRow(permission)
                }
                LabeledContent("Privacy & Security") {
                    Button("Open System Settings") {
                        Permission.openPrivacy(nil)
                    }
                }
            } footer: {
                Text("MacCove can’t change these itself. To turn one off, or back on after you denied it, use System Settings › Privacy & Security.")
            }

            ForEach(permissions.filter { $0.fix != nil }) { permission in
                if let fix = permission.fix {
                    Section {
                        fixRow(fix)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        permissions = await Permission.current()
    }

    // MARK: View Components
    private func permissionRow(_ permission: Permission) -> some View {
        HStack(spacing: 10) {
            permission.icon
                .frame(width: 25, height: 25)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(permission.status.title)
                .foregroundStyle(permission.status.color)
        }
    }

    private func fixRow(_ fix: Permission.Fix) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(fix.title)
                Text(fix.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(fix.buttonTitle, action: fix.open)
        }
    }
}

// MARK: - Permissions

private struct Permission: Identifiable {
    enum Status {
        case allowed
        /// macOS asks the first time the feature needs it.
        case notAsked
        case denied
        /// Waiting for you to allow it, in Login Items.
        case waiting
        /// macOS asks every time.
        case asksEachTime
        /// Only an app that's open can say.
        case appNotOpen

        var title: String {
            switch self {
            case .allowed: "Allowed"
            case .notAsked: "Not asked"
            case .denied: "Denied"
            case .waiting: "Waiting"
            case .asksEachTime: "Asks each time"
            case .appNotOpen: "Not open"
            }
        }

        var color: Color {
            switch self {
            case .allowed: .green
            case .denied: .red
            case .waiting, .asksEachTime: .orange
            case .notAsked, .appNotOpen: .secondary
            }
        }
    }

    /// Something that needs you, and where it's fixed.
    struct Fix {
        let title: String
        let detail: String
        var buttonTitle = "Open System Settings"
        let open: () -> Void
    }

    let id: String
    let title: String
    let detail: String
    let icon: PermissionIcon
    let status: Status
    let fix: Fix?

    /// Every permission MacCove uses, as macOS has it now.
    static func current() async -> [Permission] {
        var permissions = [accessibility()]
        permissions += await automation()
        permissions += [calendar(), reminders(), location(), contacts(), pasteboard()]
        if let helper = lowPowerModeHelper() {
            permissions.append(helper)
        }
        return permissions
    }

    private static func accessibility() -> Permission {
        let isAllowed = AppMenuExtent.isAllowed
        return Permission(
            id: "accessibility",
            title: "Accessibility",
            detail: "Keeps bubbles clear of app menus, and presses Esc in terminals",
            icon: PermissionIcon(symbol: "accessibility", color: .blue),
            status: isAllowed ? .allowed : .notAsked,
            fix: isAllowed ? nil : Fix(
                title: "Accessibility is off",
                detail: "Bubbles may cover the menus of the app in front. Turn on MacCove under Accessibility. A MacCove rebuilt since may need turning off and on again."
            ) {
                AppMenuExtent.openSettings()
            }
        )
    }

    // MARK: Automation

    private struct AutomationTarget {
        let bundleIdentifier: String
        let name: String
        let purpose: String
        /// Built into macOS, so listed even before it's been opened.
        let isBuiltIn: Bool
    }

    private static let automationTargets = [
        AutomationTarget(bundleIdentifier: MusicScripting.bundleIdentifier, name: "Music", purpose: "Favorites, and exactly where the song is", isBuiltIn: true),
        AutomationTarget(bundleIdentifier: XcodeScripting.bundleIdentifier, name: "Xcode", purpose: "Scheme names, and Stop, Run and Test Again", isBuiltIn: false),
        AutomationTarget(bundleIdentifier: "com.apple.Terminal", name: "Terminal", purpose: "Brings forward the window a command ran in", isBuiltIn: true),
        AutomationTarget(bundleIdentifier: "com.googlecode.iterm2", name: "iTerm", purpose: "Brings forward the window a command ran in, and presses Esc", isBuiltIn: false),
    ]

    /// Installed apps only. Asking an app that isn't open can't tell.
    private static func automation() async -> [Permission] {
        var permissions: [Permission] = []
        for target in automationTargets {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) != nil || target.isBuiltIn else {
                continue
            }
            let status = await automationStatus(of: target.bundleIdentifier)
            let detail = status == .appNotOpen
                ? "Automation · open \(target.name) to check"
                : "Automation · \(target.purpose)"
            permissions.append(Permission(
                id: "automation-\(target.bundleIdentifier)",
                title: "Control \(target.name)",
                detail: detail,
                icon: PermissionIcon(appBundleIdentifier: target.bundleIdentifier),
                status: status,
                fix: status == .denied ? Fix(
                    title: "MacCove can’t control \(target.name)",
                    detail: "Turn on \(target.name) under MacCove in Automation."
                ) {
                    openPrivacy("Privacy_Automation")
                } : nil
            ))
        }
        return permissions
    }

    /// Never asks: that happens the first time MacCove needs the app.
    private static func automationStatus(of bundleIdentifier: String) async -> Status {
        let status = await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        }.value
        return switch status {
        case OSStatus(noErr): .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): .notAsked
        case OSStatus(procNotFound): .appNotOpen
        default: .denied
        }
    }

    // MARK: Privacy

    private static func calendar() -> Permission {
        let status: Status = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        return Permission(
            id: "calendar",
            title: "Calendar",
            detail: "For Next meeting",
            icon: PermissionIcon(symbol: "calendar", color: .red),
            status: status,
            fix: status == .denied ? Fix(
                title: "Calendar access was denied",
                detail: "Next meeting needs it. Turn on MacCove under Calendars, with full access."
            ) {
                CalendarMonitor.openAccessSettings()
            } : nil
        )
    }

    private static func reminders() -> Permission {
        let status: Status = switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        return Permission(
            id: "reminders",
            title: "Reminders",
            detail: "For Reminders",
            icon: PermissionIcon(symbol: "checklist", color: .orange),
            status: status,
            fix: status == .denied ? Fix(
                title: "Reminders access was denied",
                detail: "Reminders needs it. Turn on MacCove under Reminders, with full access."
            ) {
                RemindersMonitor.openAccessSettings()
            } : nil
        )
    }

    private static func location() -> Permission {
        let status: Status = switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        return Permission(
            id: "location",
            title: "Location",
            detail: "For Show when to leave",
            icon: PermissionIcon(symbol: "location.fill", color: .blue),
            status: status,
            fix: status == .denied ? Fix(
                title: "Location access was denied",
                detail: "Show when to leave needs it. Turn on MacCove under Location Services."
            ) {
                CalendarMonitor.openLocationSettings()
            } : nil
        )
    }

    private static func contacts() -> Permission {
        let status: Status = switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        return Permission(
            id: "contacts",
            title: "Contacts",
            detail: "For birthday messages, and how old someone’s turning",
            icon: PermissionIcon(symbol: "person.crop.circle.fill", color: .gray),
            status: status,
            fix: status == .denied ? Fix(
                title: "Contacts access was denied",
                detail: "Birthdays can’t find who to message. Turn on MacCove under Contacts."
            ) {
                openPrivacy("Privacy_Contacts")
            } : nil
        )
    }

    /// Until macOS has asked, MacCove reads the clipboard freely.
    private static func pasteboard() -> Permission {
        let status: Status = switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: .allowed
        case .ask: .asksEachTime
        case .alwaysDeny: .denied
        default: .notAsked
        }
        let needsFix = ClipboardMonitor.isEnabled && (status == .asksEachTime || status == .denied)
        return Permission(
            id: "pasteboard",
            title: "Paste from Other Apps",
            detail: "For Clipboard history",
            icon: PermissionIcon(symbol: "doc.on.clipboard.fill", color: .indigo),
            status: status,
            fix: needsFix ? Fix(
                title: status == .denied ? "Clipboard access was denied" : "macOS asks before each copy is read",
                detail: "Clipboard history needs it. Choose Always Allow for MacCove under Paste from Other Apps."
            ) {
                ClipboardMonitor.openAccessSettings()
            } : nil
        )
    }

    /// Registered the first time Low Power Mode is switched from the
    /// notch, then waits for you in Login Items.
    private static func lowPowerModeHelper() -> Permission? {
        let status: Status
        switch SMAppService.daemon(plistName: LowPowerModeHelper.plistName).status {
        case .enabled: status = .allowed
        case .requiresApproval: status = .waiting
        case .notRegistered: status = .notAsked
        default: return nil
        }
        return Permission(
            id: "low-power-mode-helper",
            title: "Low Power Mode helper",
            detail: status == .waiting
                ? "Waiting in Login Items › Allow in the Background"
                : "Switches Low Power Mode without asking for your password",
            icon: PermissionIcon(symbol: "bolt.fill", color: .orange),
            status: status,
            fix: status == .waiting ? Fix(
                title: "Low Power Mode helper is waiting for you",
                detail: "Turn on MacCove under Allow in the Background.",
                buttonTitle: "Open Login Items"
            ) {
                SMAppService.openSystemSettingsLoginItems()
            } : nil
        )
    }

    /// Privacy & Security in System Settings, at `pane` when there's one:
    /// "Privacy_Contacts" and so on.
    static func openPrivacy(_ pane: String?) {
        let base = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        guard let url = URL(string: pane.map { "\(base)?\($0)" } ?? base) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A permission's icon: the app it's for, or a symbol on a coloured tile,
/// as System Settings draws them.
private struct PermissionIcon: View {
    private let symbol: String?
    private let color: Color
    private let appBundleIdentifier: String?

    init(symbol: String, color: Color) {
        self.symbol = symbol
        self.color = color
        appBundleIdentifier = nil
    }

    init(appBundleIdentifier: String) {
        symbol = nil
        color = .clear
        self.appBundleIdentifier = appBundleIdentifier
    }

    var body: some View {
        if let appBundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.gradient)
                .overlay {
                    Image(systemName: symbol ?? "app.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }
}

#if DEBUG
#Preview {
    PermissionsSettingsView()
}
#endif
