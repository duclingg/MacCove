import SwiftUI

/// Calendar Events in the menu bar: turning it on asks for Calendar,
/// Show When to Leave asks where you are, each only when it's chosen.
struct CalendarMenu: View {
    let calendar: CalendarMonitor
    let showToday: () -> Void

    var body: some View {
        Toggle("Calendar Events", isOn: Binding(
            get: { calendar.isEnabled },
            set: { calendar.setEnabled($0) }
        ))
        if calendar.isEnabled {
            if calendar.access == .denied {
                Button("Allow Calendar Access…") {
                    CalendarMonitor.openAccessSettings()
                }
            } else if calendar.access == .granted {
                if !calendar.calendars.isEmpty {
                    Menu("Calendars") {
                        ForEach(sources, id: \.self) { source in
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
                }
                Toggle("Show When to Leave", isOn: Binding(
                    get: { calendar.isLeaveTimeEnabled },
                    set: { calendar.setLeaveTimeEnabled($0) }
                ))
                if calendar.isLeaveTimeEnabled, calendar.locationAccess == .denied {
                    Button("Allow Location Access…") {
                        CalendarMonitor.openLocationSettings()
                    }
                }
                Button("Show Today's Events") {
                    showToday()
                }
            }
        }
    }

    /// iCloud, Google and so on, in the order the calendars are sorted.
    private var sources: [String] {
        var seen: Set<String> = []
        return calendar.calendars.map(\.source).filter { seen.insert($0).inserted }
    }
}
