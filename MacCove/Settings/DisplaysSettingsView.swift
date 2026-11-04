//
//  DisplaysSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import SwiftUI

/// Your displays, and how MacCove shows on those without a notch.
/// `NotchWindowController` and `NotchViewModel` follow these as they
/// change.
struct DisplaysSettingsView: View {
    // MARK: AppStorage
    @AppStorage(NotchSettings.noNotchVisibilityKey) private var noNotchVisibility = NotchSettings.defaultNoNotchVisibility
    @AppStorage(NotchSettings.showsHandleKey) private var showsHandle = false
    @AppStorage(NotchSettings.activityDisplayKey) private var activityDisplay = NotchSettings.defaultActivityDisplay

    // MARK: States
    @State private var displays: [Display] = []

    // MARK: View
    var body: some View {
        Form {
            Section("Your displays") {
                ForEach(displays) { display in
                    displayRow(display)
                }
            }

            Section {
                Picker("Show MacCove", selection: $noNotchVisibility) {
                    ForEach(NotchSettings.NoNotchVisibility.allCases, id: \.self) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
                // Only a tucked-away island has a place to mark.
                Toggle("Show a handle at the top edge", isOn: $showsHandle)
                    .disabled(noNotchVisibility != .duringActivities)
                Picker("Show activities on", selection: $activityDisplay) {
                    ForEach(NotchSettings.ActivityDisplay.allCases, id: \.self) { display in
                        Text(display.title).tag(display)
                    }
                }
            } header: {
                Text("Displays without a notch")
            } footer: {
                Text(footer)
            }
        }
        .formStyle(.grouped)
        .settingsSwitch()
        .onAppear(perform: refresh)
        // Plugged in, unplugged, rearranged, or the lid closed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
        // Which display shows MacCove changes with the setting.
        .onChange(of: activityDisplay) {
            refresh()
        }
        .onChange(of: noNotchVisibility) {
            refresh()
        }
    }

    private var footer: String {
        switch noNotchVisibility {
        case .duringActivities:
            "Only during activities: it slides down when something starts and hides when nothing is running."
        case .always:
            "Always: a black pill stays at the top edge, where a notch would be."
        case .never:
            "Never: MacCove shows only on a display with a notch."
        }
    }

    private func refresh() {
        let showing = NotchSettings.screen?.displayID
        displays = NSScreen.screens.map { screen in
            Display(
                id: screen.displayID ?? 0,
                name: screen.localizedName,
                hasNotch: screen.hasNotch,
                isBuiltIn: screen.isBuiltIn,
                hasMenuBar: screen == NSScreen.primary,
                // Never hides it on a display without a notch.
                isShowingMacCove: screen.displayID == showing && (screen.hasNotch || noNotchVisibility != .never)
            )
        }
    }

    // MARK: View Components
    private func displayRow(_ display: Display) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.gradient)
                .frame(width: 25, height: 25)
                .overlay {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                if let detail = display.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(display.hasNotch ? "Notch" : "No notch")
                .foregroundStyle(.secondary)
        }
    }
}

private struct Display: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let hasNotch: Bool
    let isBuiltIn: Bool
    let hasMenuBar: Bool
    let isShowingMacCove: Bool

    /// Which one has the menu bar, and which shows MacCove now. With
    /// Display with the pointer, that's the one you're using.
    var detail: String? {
        let parts = [hasMenuBar ? "Menu bar" : nil, isShowingMacCove ? "Shows MacCove" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview {
    DisplaysSettingsView()
}
#endif
