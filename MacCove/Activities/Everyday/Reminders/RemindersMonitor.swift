//
//  RemindersMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import EventKit
import OSLog
import SwiftUI

/// A reminder with a due time, from the lists you pick. Reminders with only
/// a day, and no time, aren't shown.
nonisolated struct ReminderItem: Identifiable, Equatable, Sendable {
    /// What EventKit knows it by, to complete or snooze it.
    let id: String
    let title: String
    let due: Date
    let listTitle: String
}

extension ReminderItem {
    /// Read on EventKit's queue, as the reminders arrive.
    nonisolated init?(_ reminder: EKReminder) {
        guard let components = reminder.dueDateComponents, components.hour != nil,
              let due = Calendar.current.date(from: components) else { return nil }
        let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            id: reminder.calendarItemIdentifier,
            title: title.isEmpty ? "New Reminder" : title,
            due: due,
            listTitle: reminder.calendar?.title ?? ""
        )
    }
}

/// Reminders from the Reminders app, as the notch shows them: the one due
/// now, with Snooze 1 Hour and Complete, or the day's list to tick off when
/// several are due, and a check as one is completed.
///
/// Reads EventKit with full access, asked for when Reminders is turned on,
/// and again whenever its database changes. Only reminders with a due time
/// count: those due today, and any from the last week not yet done.
@Observable
final class RemindersMonitor {
    enum Event {
        /// Something new to show, or what's shown moved on.
        case started
        /// Nothing left to show.
        case ended
    }

    enum Phase: Equatable {
        /// One reminder is due: Snooze or Complete it.
        case due
        /// Several are, and the day's list shows to tick them off.
        case many
        /// Just completed: a check, then it leaves.
        case completed
    }

    typealias Access = CalendarMonitor.Access
    /// A list to pick in Settings, by account.
    typealias ListChoice = CalendarMonitor.CalendarChoice

    /// Reminders', where a reminder comes from.
    static let appBundleIdentifier = "com.apple.reminders"
    static let enabledKey = "RemindersEnabled"
    /// Lists left out, rather than the ones picked, so a new list counts
    /// until it's unticked.
    static let excludedKey = "RemindersExcludedLists"

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: RemindersMonitor.enabledKey)
    private(set) var access: Access = .notDetermined
    /// Every list of reminders, by account and then by name.
    private(set) var lists: [ListChoice] = []
    private(set) var excludedLists = Set(UserDefaults.standard.stringArray(forKey: RemindersMonitor.excludedKey) ?? [])
    /// Due now or overdue, the oldest first, but not those ticked off.
    private(set) var due: [ReminderItem] = []
    /// The day's list: everything due today and anything overdue, by when
    /// it's due. Those ticked off here stay in their place, checked, until
    /// the notch closes, so the list doesn't jump about under the cursor.
    private(set) var rows: [ReminderItem] = []
    /// Ticked off in the list, still showing.
    private(set) var ticked: Set<String> = []
    /// Completed with Complete, showing its check.
    private(set) var completed: ReminderItem?

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the notch is open or under the cursor, when a check or a
    /// ticked-off row waits to leave until you're done with it.
    @ObservationIgnored var isInUse: () -> Bool = { false }

    /// Remade once access is granted: one made before sees no lists.
    @ObservationIgnored private var store = EKEventStore()
    /// Not done yet, from a week ago to the end of today, in order.
    @ObservationIgnored private var fetched: [ReminderItem] = []
    /// The ones ticked off, kept to show in their place.
    @ObservationIgnored private var tickedItems: [ReminderItem] = []
    @ObservationIgnored private var fetchedAt: Date?
    /// Counts reads of the database, so an older one that answers late is
    /// ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var storeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var completedTimer: Task<Void, Never>?
    @ObservationIgnored private var isCompletedDue = false
    @ObservationIgnored private var leaving: Task<Void, Never>?
    /// What was last shown, to say when that changes.
    @ObservationIgnored private var shownKey: String?

    /// How often what's due is worked out again.
    private static let tickInterval: Duration = .seconds(15)
    /// The database is read again this often, besides when it says it
    /// changed.
    private static let refetchInterval: TimeInterval = 5 * 60
    /// Overdue reminders older than this many days are left alone.
    private static let lookBackDays = 6
    /// How long the check shows after Complete.
    private static let completedDuration: Duration = .seconds(2.5)
    /// Past due by more than this, a reminder is overdue rather than just
    /// due.
    static let overdueAfter: TimeInterval = 60 * 60
    private static let log = Logger(subsystem: "com.justinhoang.MacCove", category: "Reminders")

    var phase: Phase? {
        if completed != nil { return .completed }
        if due.count > 1 || !ticked.isEmpty { return .many }
        return due.isEmpty ? nil : .due
    }

    var isShown: Bool {
        phase != nil
    }

    /// The day's list, but not those ticked off.
    var remaining: [ReminderItem] {
        rows.filter { !ticked.contains($0.id) }
    }

    static func isOverdue(_ reminder: ReminderItem, at now: Date) -> Bool {
        now.timeIntervalSince(reminder.due) > overdueAfter
    }

    // MARK: - Turning on

    /// Asks for full access to Reminders the first time it's turned on.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard isEnabled else { return }
        refreshPermissions()
        if access == .notDetermined {
            requestAccess()
        }
    }

    /// Turned off: nothing more shows.
    func stop() {
        ticking?.cancel()
        ticking = nil
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        storeObserver = nil
        generation += 1
        fetched = []
        fetchedAt = nil
        tickedItems = []
        ticked = []
        completed = nil
        completedTimer?.cancel()
        isCompletedDue = false
        leaving?.cancel()
        due = []
        rows = []
        if shownKey != nil {
            shownKey = nil
            onEvent?(.ended)
        }
    }

    /// When Settings opens: access may have been granted or taken away in
    /// System Settings since.
    func refreshPermissions() {
        let previous = access
        access = switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        // However it was granted: at the prompt or in System Settings.
        if access == .granted, previous != .granted {
            store = EKEventStore()
        }
        if isEnabled, access == .granted, ticking == nil {
            begin()
        } else if access != .granted, ticking != nil {
            stop()
        }
    }

    private func requestAccess() {
        // Called back on any queue.
        store.requestFullAccessToReminders { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.refreshPermissions()
                // The status can lag the answer by a moment: read it again
                // rather than stay Not Asked.
                for _ in 0..<6 where self.access == .notDetermined {
                    try? await Task.sleep(for: .milliseconds(500))
                    self.refreshPermissions()
                }
            }
        }
    }

    static func openAccessSettings() {
        SystemSettings.openPrivacy("Privacy_Reminders")
    }

    private func begin() {
        if storeObserver == nil {
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                self.tick()
            }
        }
    }

    // MARK: - Lists

    func isIncluded(_ list: ListChoice) -> Bool {
        !excludedLists.contains(list.id)
    }

    func setIncluded(_ list: ListChoice, _ included: Bool) {
        if included {
            excludedLists.remove(list.id)
        } else {
            excludedLists.insert(list.id)
        }
        UserDefaults.standard.set(Array(excludedLists), forKey: Self.excludedKey)
        reload()
    }

    // MARK: - Reading reminders

    private func tick() {
        let now = Date.now
        let isStale = fetchedAt.map { now.timeIntervalSince($0) > Self.refetchInterval || !Calendar.current.isDate($0, inSameDayAs: now) } ?? true
        if isStale {
            reload()
        } else {
            update()
        }
    }

    /// Those not done yet, due from a week ago to the end of today.
    private func reload() {
        guard isEnabled, access == .granted else { return }
        let all = store.calendars(for: .reminder)
        lists = all
            .map { ListChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        let included = all.filter { !excludedLists.contains($0.calendarIdentifier) }
        fetchedAt = .now
        generation += 1
        let thisGeneration = generation
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        guard !included.isEmpty,
              let start = calendar.date(byAdding: .day, value: -Self.lookBackDays, to: startOfToday),
              let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            fetched = []
            update()
            return
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: included)
        // Called back on any queue, so they're copied out there.
        store.fetchReminders(matching: predicate) { @Sendable [weak self] reminders in
            let items = (reminders ?? [])
                .compactMap { ReminderItem($0) }
                .sorted { $0.due < $1.due }
            Task { @MainActor in
                guard let self, self.generation == thisGeneration else { return }
                self.fetched = items
                self.update()
            }
        }
    }

    // MARK: - What shows

    private func update() {
        guard isEnabled, access == .granted else { return }
        let now = Date.now
        // A read that started before one was ticked off or completed may
        // still have it.
        let done = Set(tickedItems.map(\.id)).union(completed.map { [$0.id] } ?? [])
        let open = fetched.filter { !done.contains($0.id) }
        let newDue = open.filter { $0.due <= now }
        let newRows = (open + tickedItems).sorted { $0.due < $1.due }
        if newDue != due {
            due = newDue
        }
        if newRows != rows {
            rows = newRows
        }

        let key = currentKey
        guard key != shownKey else { return }
        let wasShown = shownKey != nil
        shownKey = key
        if key != nil {
            onEvent?(.started)
        } else if wasShown {
            onEvent?(.ended)
        }
    }

    /// One for each thing shown, so the notch hears when it changes: a new
    /// reminder due, the list, or a check.
    private var currentKey: String? {
        switch phase {
        case .completed?: completed.map { "completed:\($0.id)" }
        case .many?: "many"
        case .due?: due.first.map { "due:\($0.id)" }
        case nil: nil
        }
    }

    // MARK: - Actions

    /// The one due, from its Complete button: a check, then it leaves.
    func complete() {
        guard let reminder = due.first, setCompleted(reminder.id, true) else { return }
        completed = reminder
        isCompletedDue = false
        completedTimer?.cancel()
        completedTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.completedDuration)
            guard !Task.isCancelled, let self else { return }
            self.isCompletedDue = true
            self.leaveIfDue()
        }
        update()
    }

    /// Ticks one off in the list, or back on again.
    func toggle(_ reminder: ReminderItem) {
        let isTicked = ticked.contains(reminder.id)
        guard setCompleted(reminder.id, !isTicked) else { return }
        if isTicked {
            ticked.remove(reminder.id)
            tickedItems.removeAll { $0.id == reminder.id }
            if !fetched.contains(where: { $0.id == reminder.id }) {
                fetched.append(reminder)
                fetched.sort { $0.due < $1.due }
            }
        } else {
            ticked.insert(reminder.id)
            tickedItems.append(reminder)
        }
        update()
    }

    /// The one due, an hour from now. Its alert moves with it, so
    /// Reminders says so again then too.
    func snooze() {
        guard let item = due.first,
              let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        let calendar = Calendar.current
        let now = Date.now
        guard let later = calendar.date(byAdding: .hour, value: 1, to: now),
              let until = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: later)) else { return }
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: until)
        // Floating times stay floating.
        components.timeZone = reminder.dueDateComponents?.timeZone == nil ? nil : calendar.timeZone
        reminder.dueDateComponents = components
        let alarms = reminder.alarms ?? []
        let timed = alarms.filter { $0.absoluteDate != nil }
        if !timed.isEmpty {
            for alarm in timed {
                reminder.removeAlarm(alarm)
            }
            let hasRelative = alarms.contains { $0.absoluteDate == nil && $0.structuredLocation == nil }
            if !hasRelative {
                reminder.addAlarm(EKAlarm(absoluteDate: until))
            }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            Self.log.error("Couldn't snooze a reminder: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let index = fetched.firstIndex(where: { $0.id == item.id }) {
            fetched[index] = ReminderItem(id: item.id, title: item.title, due: until, listTitle: item.listTitle)
            fetched.sort { $0.due < $1.due }
        }
        update()
    }

    func openReminders() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func setCompleted(_ id: String, _ isCompleted: Bool) -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        reminder.isCompleted = isCompleted
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            Self.log.error("Couldn't change a reminder: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A check that has had its time, and rows ticked off, leave once the
    /// notch closes, unless it's open or under the cursor; then they wait
    /// to be asked again.
    func leaveIfDue(after delay: Duration = .zero) {
        guard (isCompletedDue && completed != nil) || !ticked.isEmpty else { return }
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isInUse() else { return }
            if self.isCompletedDue {
                self.isCompletedDue = false
                self.completed = nil
            }
            self.ticked = []
            self.tickedItems = []
            self.update()
        }
    }
}

extension Color {
    /// The design's orange for reminders.
    static let reminder = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    /// Dark text on the orange Complete button.
    static let reminderOnAccent = Color(red: 43 / 255, green: 23 / 255, blue: 0)
    /// The design's red for overdue.
    static let reminderOverdue = Color(red: 1, green: 105 / 255, blue: 97 / 255)
    /// The design's green for the check.
    static let reminderDone = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
}

#if DEBUG
extension RemindersMonitor {
    /// Shows what's given and stays that way, for SwiftUI previews.
    static func preview(
        due: [ReminderItem],
        rows: [ReminderItem] = [],
        ticked: Set<String> = [],
        completed: ReminderItem? = nil
    ) -> RemindersMonitor {
        let monitor = RemindersMonitor()
        monitor.due = due
        monitor.rows = rows
        monitor.ticked = ticked
        monitor.completed = completed
        return monitor
    }
}
#endif
