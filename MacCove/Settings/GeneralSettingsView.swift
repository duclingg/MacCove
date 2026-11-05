//
//  GeneralSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    // MARK: AppStorage
    @AppStorage(NotchSettings.openingKey) private var notchOpens = NotchSettings.defaultOpening
    @AppStorage(NotchSettings.trackpadFeedbackKey) private var trackpadFeedback = true
    @AppStorage(NotchSettings.hideInFullScreenKey) private var hideInFullScreen = true
    @AppStorage(NotchSettings.maxActivitiesKey) private var maxActivities = NotchSettings.defaultMaxActivities

    // MARK: States
    @Environment(MenuBarItem.self) private var menuBar
    @Environment(NotchCommands.self) private var notch
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Toggle(isOn: Binding(
                    get: { menuBar.isShown },
                    set: { menuBar.setShown($0) }
                )) {
                    Text("Show MacCove in the menu bar")
                    Text("Settings and Quit live there. The same switch is in System Settings › Menu Bar. If hidden, open MacCove again to see this window.")
                }
                Picker("Open the notch", selection: $notchOpens) {
                    ForEach(NotchSettings.Opening.allCases, id: \.self) { opening in
                        Text(opening.title).tag(opening)
                    }
                }
                Toggle("Trackpad feedback when it opens", isOn: $trackpadFeedback)
            }

            Section("Notch") {
                Toggle(isOn: $hideInFullScreen) {
                    Text("Hide while an app is full screen")
                    Text("Touch ID at the lock screen still shows. Move the pointer to the top of the screen to bring the rest back.")
                }
                Picker("Show at most", selection: $maxActivities) {
                    ForEach(NotchSettings.maxActivitiesOptions, id: \.self) { count in
                        Text(count == 1 ? "1 activity" : "\(count) activities").tag(count)
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Show") {
                        notch.showWelcome()
                    }
                } label: {
                    Text("Show Welcome Again")
                    Text("Runs the setup from the first launch.")
                }
                // Clicked twice, like Merge in the notch: the first click
                // says what goes, the second within a few seconds resets.
                LabeledContent {
                    Button(isConfirmingReset ? "Click Again to Reset" : "Reset…", role: .destructive) {
                        if isConfirmingReset {
                            ResetEverything.resetAndRelaunch()
                        } else {
                            isConfirmingReset = true
                        }
                    }
                } label: {
                    Text("Reset all settings")
                    Text(isConfirmingReset ? Self.resetDetail : "Takes out everything MacCove set up, then reopens it")
                }
                .tint(.red)
            }
        }
        .formStyle(.grouped)
        .settingsSwitch()
        .onAppear {
            launchAtLogin.refresh()
        }
        // Not clicked again in time: back to Reset….
        .task(id: isConfirmingReset) {
            guard isConfirmingReset else { return }
            try? await Task.sleep(for: .seconds(5))
            isConfirmingReset = false
        }
    }

    private static let resetDetail = "Takes out the hooks in Claude Code, Codex and Cursor, the lines in ~/.zshrc, Xcode’s Behaviors that run MacCove’s scripts, and the scripts themselves. Signs out of GitHub, removes the Low Power Mode helper and the login item, empties the shelf, and has macOS forget MacCove’s permissions, except Local Network, which macOS keeps: change that under Local Network in Privacy & Security. Then MacCove reopens to the welcome. Backups of other apps’ settings are kept."
}

#if DEBUG
#Preview {
    GeneralSettingsView()
        .environment(MenuBarItem())
        .environment(NotchCommands())
}
#endif
