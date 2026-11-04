//
//  GeneralSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import SwiftUI

private enum NotchOpenType: String {
    case hovered, shortPause, whenClicked
}

struct GeneralSettingsView: View {
    // MARK: AppStorage
    @AppStorage("ShowInMenuBar") private var showInMenuBar = true
    @AppStorage("NotchOpens") private var notchOpens: NotchOpenType = .whenClicked
    @AppStorage("TrackpadFeedback") private var trackpadFeedback = true
    @AppStorage("HideInFullScreen") private var hideInFullScreen = true
    @AppStorage("MaxNotchActivities") private var maxActivities = 3
    
    // MARK: States
    @State private var launchAtLogin = LaunchAtLogin()
    
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Toggle(isOn: $showInMenuBar) {
                    // TODO: Show in menu bar setting
                    Text("Show MacCove in the menu bar")
                    Text("Settings and Quit live there. If hidden, open MacCove again to see this window.")
                }
                Picker("Open the notch", selection: $notchOpens) {
                    // TODO: Notch opens settings
                    Group {
                        Button("When hovered") {
                            
                        }.tag(NotchOpenType.hovered)
                        Button("After a short pause") {
                            
                        }.tag(NotchOpenType.shortPause)
                        Button("Only when clicked") {
                            
                        }.tag(NotchOpenType.whenClicked)
                    }
                    .buttonStyle(.plain)
                }
                // TODO: Trackpad setting
                Toggle("Trackpad feedback when it opens", isOn: $trackpadFeedback)
            }
            
            Section("Notch") {
                Toggle(isOn: $hideInFullScreen) {
                    // TODO: Hide in full screen setting
                    Text("Hide while an app is full screen")
                    Text("Calls and alarms still show")
                }
                Picker("Show at most", selection: $maxActivities) {
                    // TODO: Max activities settings
                    Group {
                        Button("3 activites") {
                            
                        }.tag(3)
                        Button("2 activites") {
                            
                        }.tag(2)
                        Button("1 activity") {
                            
                        }.tag(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Section {
                LabeledContent {
                    Button("Show") {
                        // TODO: Show Welcome Again
                    }
                } label: {
                    Text("Show Welcome Again")
                    Text("Runs the setup from the first launch.")
                }
                LabeledContent("Reset all settings") {
                    Button("Reset...", role: .destructive) {
                        // TODO: Reset all settings
                    }
                }
                .tint(.red)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear {
            launchAtLogin.refresh()
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView()
}
#endif
