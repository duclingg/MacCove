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
    @Environment(RemindersMonitor.self) private var reminders
    @Environment(DeviceBatteryMonitor.self) private var deviceBatteries
    @Environment(FileShelf.self) private var shelf
    @AppStorage(ClipboardMonitor.enabledKey) private var isClipboardEnabled = false
    @Environment(NotchCommands.self) private var notch
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
                activityToggle("Reminders", detail: remindersDetail, isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { reminders.setEnabled($0) }
                ))
                if reminders.isEnabled {
                    remindersOptions
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
                if isClipboardEnabled {
                    LabeledContent {
                        Button("Show History") {
                            notch.showClipboardHistory()
                        }
                    } label: {
                        Text("Your recent copies")
                        Text("Opens in the notch")
                    }
                }
                if isClipboardEnabled, isClipboardRestricted {
                    allowRow(
                        "macOS asks before MacCove reads each copy",
                        detail: "Choose Always Allow in Paste from Other Apps"
                    ) {
                        ClipboardMonitor.openAccessSettings()
                    }
                }
                activityToggle(
                    "File shelf",
                    detail: "Drag files to the notch to keep them handy, until you drag them out",
                    isOn: Binding(
                        get: { shelf.isEnabled },
                        set: { shelf.setEnabled($0) }
                    )
                )
                if shelf.isEnabled, !shelf.items.isEmpty {
                    LabeledContent {
                        Button("Show Shelf") {
                            notch.showShelf()
                        }
                    } label: {
                        Text(shelf.items.count == 1 ? "1 file on the shelf" : "\(shelf.items.count) files on the shelf")
                        Text("Opens in the notch")
                    }
                }
                activityToggle("Device batteries", detail: deviceBatteriesDetail, isOn: Binding(
                    get: { deviceBatteries.isEnabled },
                    set: { deviceBatteries.setEnabled($0) }
                ))
                if deviceBatteries.isEnabled, !deviceBatteries.devices.isEmpty {
                    let count = deviceBatteries.devices.count
                    LabeledContent {
                        Button("Show Devices") {
                            notch.showDeviceBatteries()
                        }
                    } label: {
                        Text(count == 1 ? "1 device connected" : "\(count) devices connected")
                        Text("Opens in the notch")
                    }
                }
            } header: {
                Text("Everyday")
            } footer: {
                Text("Turning one off stops MacCove watching for it. Calendar and Reminders ask macOS for access the first time.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            calendar.refreshPermissions()
            reminders.refreshPermissions()
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

    private var deviceBatteriesDetail: String {
        let levels = DeviceBatteryMonitor.lowThresholds.map { "\($0)%" }
        return "Mice, keyboards, trackpads and controllers. Warns at \(levels.formatted(.list(type: .and)))."
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
                picker("Calendars", choices: calendar.calendars, isIncluded: calendar.isIncluded, setIncluded: calendar.setIncluded)
            }
            LabeledContent {
                Button("Show Today") {
                    notch.showTodayEvents()
                }
            } label: {
                Text("The rest of today")
                Text("Opens in the notch")
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

    // MARK: Reminders
    private var remindersDetail: String {
        guard reminders.isEnabled else { return "Reminders with a due time, as they come due" }
        switch reminders.access {
        case .notDetermined:
            return "Asks for access to Reminders"
        case .denied:
            return "Needs access to Reminders"
        case .granted:
            let included = reminders.lists.filter { reminders.isIncluded($0) }.map(\.title)
            guard !included.isEmpty else { return "No lists chosen" }
            let names = included.count > 3
                ? "\(included.prefix(3).joined(separator: ", ")) and \(included.count - 3) more"
                : included.formatted(.list(type: .and))
            return "\(names) · from Reminders"
        }
    }

    /// Under Reminders while it's on: access first, then which lists count.
    @ViewBuilder private var remindersOptions: some View {
        switch reminders.access {
        case .denied:
            allowRow("MacCove can’t see your reminders", detail: "Turn on MacCove in Privacy & Security › Reminders") {
                RemindersMonitor.openAccessSettings()
            }
        case .granted:
            if !reminders.lists.isEmpty {
                picker("Lists", choices: reminders.lists, isIncluded: reminders.isIncluded, setIncluded: reminders.setIncluded)
            }
        case .notDetermined:
            EmptyView()
        }
    }

    // MARK: Pickers
    /// Each account's calendars or lists, ticked when they count.
    private func picker(
        _ label: String,
        choices: [CalendarMonitor.CalendarChoice],
        isIncluded: @escaping (CalendarMonitor.CalendarChoice) -> Bool,
        setIncluded: @escaping (CalendarMonitor.CalendarChoice, Bool) -> Void
    ) -> some View {
        // iCloud, Google and so on, in the order the choices are sorted.
        var seen: Set<String> = []
        let sources = choices.map(\.source).filter { seen.insert($0).inserted }
        let count = choices.filter(isIncluded).count
        let title = switch count {
        case choices.count: "All"
        case 0: "None"
        default: "\(count) of \(choices.count)"
        }
        return LabeledContent(label) {
            Menu(title) {
                ForEach(sources, id: \.self) { source in
                    Section(source) {
                        ForEach(choices.filter { $0.source == source }) { choice in
                            Toggle(choice.title, isOn: Binding(
                                get: { isIncluded(choice) },
                                set: { setIncluded(choice, $0) }
                            ))
                        }
                    }
                }
            }
            .fixedSize()
        }
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
        .environment(RemindersMonitor())
        .environment(DeviceBatteryMonitor())
        .environment(FileShelf(loadsSaved: false))
        .environment(NotchCommands())
}
#endif
