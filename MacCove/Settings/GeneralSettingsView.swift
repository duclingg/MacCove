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
                LabeledContent("Reset all settings") {
                    Button("Reset…", role: .destructive) {
                        isConfirmingReset = true
                    }
                }
                .tint(.red)
            }
        }
        .formStyle(.grouped)
        .settingsSwitch()
        .onAppear {
            launchAtLogin.refresh()
        }
        .confirmationDialog("Reset All Settings?", isPresented: $isConfirmingReset) {
            Button("Reset and Reopen MacCove", role: .destructive) {
                Self.resetAndRelaunch()
            }
        } message: {
            Text("Every setting goes back to how it was the first time MacCove opened, and MacCove reopens. GitHub stays signed in, and what you set up in Developer Tools stays set up.")
        }
    }

    /// Clears MacCove's settings, keeping the GitHub sign-in, then opens a
    /// new MacCove and quits this one, so every monitor starts again from
    /// its defaults rather than what it read at launch.
    private static func resetAndRelaunch() {
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier else { return }
        let kept = [GitHubSetup.sourceKey, GitHubSetup.repositoriesKey, XcodeBehaviorScripts.setUpKey].compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        }
        defaults.removePersistentDomain(forName: domain)
        for (key, value) in kept {
            defaults.set(value, forKey: key)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView()
        .environment(MenuBarItem())
        .environment(NotchCommands())
}
#endif
