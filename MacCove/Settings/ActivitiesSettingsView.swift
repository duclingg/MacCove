//
//  ActivitiesSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import SwiftUI

struct ActivitiesSettingsView: View {
    // MARK: States
    @Environment(NowPlayingModel.self) private var nowPlaying
    @Environment(BatteryMonitor.self) private var battery
    @Environment(SignInMonitor.self) private var signIn
    @Environment(ClipboardMonitor.self) private var clipboard
    @Environment(CalendarMonitor.self) private var calendar
    @AppStorage(ClipboardMonitor.enabledKey) private var isClipboardEnabled = false
    @State private var isClipboardRestricted = false

    // MARK: View
    var body: some View {
        Form {
            Section("System") {
                activityToggle("Now Playing", detail: "Music, podcasts and video from any app", isOn: Binding(
                    get: { nowPlaying.isEnabled },
                    set: { nowPlaying.setEnabled($0) }
                ))
                activityToggle("Battery and charging", detail: batteryDetail, isOn: Binding(
                    get: { battery.isEnabled },
                    set: { battery.setEnabled($0) }
                ))
                activityToggle("Touch ID at the lock screen", detail: "Shows as you unlock", isOn: Binding(
                    get: { signIn.isEnabled },
                    set: { signIn.setEnabled($0) }
                ))
            }

            Section {
                activityToggle("Next meeting", detail: calendarDetail, isOn: Binding(
                    get: { calendar.isEnabled },
                    set: { calendar.setEnabled($0) }
                ))
                if calendar.isEnabled {
                    calendarOptions
                }
                activityToggle(
                    "Clipboard history",
                    detail: "Kept 24 hours, on this Mac only. Passwords are never kept.",
                    isOn: Binding(
                        get: { isClipboardEnabled },
                        set: { enabled in
                            isClipboardEnabled = enabled
                            if enabled {
                                clipboard.start()
                            } else {
                                clipboard.stop()
                            }
                        }
                    )
                )
                if isClipboardEnabled, isClipboardRestricted {
                    allowRow(
                        "macOS asks before MacCove reads each copy",
                        detail: "Choose Always Allow in Paste from Other Apps"
                    ) {
                        ClipboardMonitor.openAccessSettings()
                    }
                }
            } header: {
                Text("Everyday")
            } footer: {
                Text("Turning one off stops MacCove watching for it. Calendar asks macOS for access the first time.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            calendar.refreshPermissions()
            isClipboardRestricted = ClipboardMonitor.isAccessRestricted
        }
    }

    // MARK: View Components
    private func activityToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsSwitch()
    }

    /// Something macOS hasn't allowed, with a button to where it's fixed.
    private func allowRow(_ title: String, detail: String, open: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Allow…", action: open)
        }
    }

    // MARK: System
    private var batteryDetail: String {
        let levels = BatteryMonitor.lowBatteryThresholds.map { "\($0)%" }
        return "Warns at \(levels.formatted(.list(type: .and))), and shows when it’s charging"
    }

    // MARK: Calendar
    private var calendarDetail: String {
        guard calendar.isEnabled else { return "From Calendar" }
        switch calendar.access {
        case .notDetermined:
            return "Asks for access to Calendar"
        case .denied:
            return "Needs access to Calendar"
        case .granted:
            let included = calendar.calendars.filter { calendar.isIncluded($0) }.map(\.title)
            guard !included.isEmpty else { return "No calendars chosen" }
            let names = included.count > 3
                ? "\(included.prefix(3).joined(separator: ", ")) and \(included.count - 3) more"
                : included.formatted(.list(type: .and))
            return "\(names) · from Calendar"
        }
    }

    /// Under Next meeting while it's on: access first, then which
    /// calendars count and when to leave.
    @ViewBuilder private var calendarOptions: some View {
        switch calendar.access {
        case .denied:
            allowRow("MacCove can’t see your calendars", detail: "Turn on MacCove in Privacy & Security › Calendars") {
                CalendarMonitor.openAccessSettings()
            }
        case .granted:
            if !calendar.calendars.isEmpty {
                calendarPicker
            }
            activityToggle(
                "Show when to leave",
                detail: "For events with a place, from where you are",
                isOn: Binding(
                    get: { calendar.isLeaveTimeEnabled },
                    set: { calendar.setLeaveTimeEnabled($0) }
                )
            )
            if calendar.isLeaveTimeEnabled, calendar.locationAccess == .denied {
                allowRow("MacCove can’t see where you are", detail: "Turn on MacCove in Privacy & Security › Location Services") {
                    CalendarMonitor.openLocationSettings()
                }
            }
        case .notDetermined:
            EmptyView()
        }
    }

    /// Each account's calendars, ticked when their events count.
    private var calendarPicker: some View {
        LabeledContent("Calendars") {
            Menu(calendarPickerTitle) {
                ForEach(calendarSources, id: \.self) { source in
                    Section(source) {
                        ForEach(calendar.calendars.filter { $0.source == source }) { choice in
                            Toggle(choice.title, isOn: Binding(
                                get: { calendar.isIncluded(choice) },
                                set: { calendar.setIncluded(choice, $0) }
                            ))
                        }
                    }
                }
            }
            .fixedSize()
        }
    }

    private var calendarPickerTitle: String {
        let count = calendar.calendars.filter { calendar.isIncluded($0) }.count
        return switch count {
        case calendar.calendars.count: "All"
        case 0: "None"
        default: "\(count) of \(calendar.calendars.count)"
        }
    }

    /// iCloud, Google and so on, in the order the calendars are sorted.
    private var calendarSources: [String] {
        var seen: Set<String> = []
        return calendar.calendars.map(\.source).filter { seen.insert($0).inserted }
    }
}

#if DEBUG
#Preview {
    ActivitiesSettingsView()
        .environment(NowPlayingModel(music: MusicScripting()))
        .environment(BatteryMonitor())
        .environment(SignInMonitor())
        .environment(ClipboardMonitor())
        .environment(CalendarMonitor())
}
#endif
