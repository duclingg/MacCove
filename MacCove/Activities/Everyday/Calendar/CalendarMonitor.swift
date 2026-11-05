//
//  CalendarMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import Contacts
import CoreLocation
import EventKit
import MapKit
import SwiftUI

/// Somewhere on the map, as plain numbers so it can cross from MapKit's
/// and Core Location's callbacks.
nonisolated struct GeoCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

/// One occurrence of an event, from the calendars you pick.
struct CalendarEvent: Identifiable, Equatable {
    /// Each occurrence of a repeating event shares its identifier, so the
    /// start goes with it.
    let id: String
    /// What Calendar knows it by, to open it there.
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// As written in the event: an address or a place's name.
    let location: String?
    /// Where it is, when the location was picked from Calendar's
    /// suggestions. Otherwise the location is looked up.
    let coordinate: GeoCoordinate?
    let calendarTitle: String
    let color: Color
    /// From the Birthdays calendar, which comes from Contacts.
    let isBirthday: Bool
    /// The person whose birthday it is.
    let birthdayContactID: String?
    /// A Zoom, Meet, Teams, Webex or FaceTime link: a meeting, with a
    /// button to join it.
    var videoLink: VideoLink?
    /// Who else is invited, by name, organizer included. Not those who
    /// declined.
    var attendees: [String] = []
    /// Repeats, so Calendar needs the occurrence's date to show this one
    /// rather than the first.
    var isRecurring = false
    /// When this occurrence was due to start, even if it's been moved.
    var occurrenceDate: Date?

    var isMeeting: Bool {
        videoLink != nil
    }
}

/// Where a meeting happens, from its location, URL or notes.
struct VideoLink: Equatable {
    let url: URL
    /// "Zoom", "Google Meet" and so on.
    let service: String

    /// The services known, by the domain their links are on.
    private static let services: [(domain: String, name: String)] = [
        ("zoom.us", "Zoom"),
        ("meet.google.com", "Google Meet"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("webex.com", "Webex"),
        ("facetime.apple.com", "FaceTime"),
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first link to a known service in the text, in order.
    static func find(in texts: [String?]) -> VideoLink? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            let links = detector?.matches(in: text, range: range).compactMap(\.url) ?? []
            if let link = links.lazy.compactMap(Self.init(url:)).first {
                return link
            }
        }
        return nil
    }

    /// Zoom's own subdomains, like us02web.zoom.us, count.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(),
              let service = Self.services.first(where: { host == $0.domain || host.hasSuffix("." + $0.domain) }) else { return nil }
        self.url = url
        self.service = service.name
    }

    #if DEBUG
    init(url: URL, service: String) {
        self.url = url
        self.service = service
    }
    #endif
}

/// Events from Calendar, as the notch shows them: minutes until the next
/// one, when to leave for it, the time left while it's on, all-day events
/// and birthdays each morning, a heads-up the night before an early start,
/// and the rest of the day.
///
/// Reads EventKit with full access, asked for when Next Meeting is turned
/// on, and again whenever Calendar's database changes. Events with a video
/// link are meetings: they show a few minutes before, with a button to
/// join, and open by themselves as they start. Invitations you declined
/// are skipped. With Show When to Leave on, MapKit's driving time from
/// where you are gives a time to leave for events with a location.
@Observable
final class CalendarMonitor {
    enum Event {
        /// Something new to show, or what's shown moved on.
        case started
        /// Time to leave for the next event, or a meeting starting: opens
        /// by itself.
        case needsYou
        /// Nothing left to show.
        case ended
    }

    enum Phase: String {
        /// Coming up in the next 15 minutes, or before the time to leave.
        /// A meeting, in the next 5.
        case upcoming
        /// Time to leave, from the drive there.
        case leave
        /// A meeting, for its first few minutes: time to join.
        case starting
        /// On now.
        case during
        /// The day's all-day events and birthdays, once each morning.
        case allDay
        /// The night before an event that starts before 9 AM.
        case tomorrow
    }

    struct Activity: Equatable {
        var phase: Phase
        var event: CalendarEvent
        /// While it's on: what comes straight after it.
        var next: CalendarEvent?
        /// All-day: how many others there are today.
        var moreCount = 0
        /// A birthday: how old they're turning, when Contacts says.
        var age: Int?

        /// One for each event and phase, so dismissing the minutes until
        /// it starts doesn't hide the time to leave, or the time left once
        /// it's on.
        var key: String {
            "\(event.id)@\(phase.rawValue)"
        }
    }

    enum Access: Equatable {
        case notDetermined
        case granted
        case denied
    }

    /// A calendar to pick in the menu bar.
    struct CalendarChoice: Identifiable, Equatable {
        let id: String
        let title: String
        /// iCloud, Google, On My Mac and so on.
        let source: String
    }

    /// Calendar's, where an event comes from.
    static let appBundleIdentifier = "com.apple.iCal"
    static let enabledKey = "CalendarEventsEnabled"
    /// Calendars left out, rather than the ones picked, so a new calendar
    /// counts until it's unticked.
    static let excludedKey = "CalendarEventsExcludedCalendars"
    static let leaveTimeKey = "CalendarEventsShowWhenToLeave"
    private static let allDayShownKey = "CalendarEventsAllDayShownOn"
    private static let tomorrowShownKey = "CalendarEventsTomorrowShownOn"

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: CalendarMonitor.enabledKey)
    private(set) var isLeaveTimeEnabled = UserDefaults.standard.bool(forKey: CalendarMonitor.leaveTimeKey)
    private(set) var access: Access = .notDetermined
    private(set) var locationAccess: Access = .notDetermined
    /// Every calendar with events, by source and then by name.
    private(set) var calendars: [CalendarChoice] = []
    private(set) var excludedCalendars = Set(UserDefaults.standard.stringArray(forKey: CalendarMonitor.excludedKey) ?? [])
    /// What's shown, `nil` when there's nothing.
    private(set) var activity: Activity?
    /// The rest of today, opened from the menu bar or the event's tile.
    private(set) var isAgendaOpen = false
    /// What's left of today: all-day events first, then the rest in order.
    private(set) var today: [CalendarEvent] = []
    /// The drive to each event with a location, in seconds.
    private(set) var travelTimes: [String: TimeInterval] = [:]

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the notch is open or under the cursor, when a heads-up or
    /// the agenda waits to leave until you're done with it.
    @ObservationIgnored var isInUse: () -> Bool = { false }

    /// Remade once access is granted: one made before sees no calendars.
    @ObservationIgnored private var store = EKEventStore()
    private let contacts = CNContactStore()
    private let location = LocationProvider()
    /// Today's and tomorrow's, in order.
    @ObservationIgnored private var events: [CalendarEvent] = []
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var storeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var dismissed: Set<String> = []
    /// Events it's been time to leave for. It stays time to leave until
    /// they start, even if the traffic clears, so the notch doesn't open
    /// for them twice.
    @ObservationIgnored private var leavingFor: Set<String> = []
    /// The morning's all-day events or the night-before heads-up, until it
    /// has had its time.
    @ObservationIgnored private var headsUp: Activity?
    @ObservationIgnored private var headsUpTimer: Task<Void, Never>?
    @ObservationIgnored private var isHeadsUpDue = false
    @ObservationIgnored private var leaving: Task<Void, Never>?
    /// Where each event's location was found, by event.
    @ObservationIgnored private var destinations: [String: GeoCoordinate] = [:]
    @ObservationIgnored private var travelFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var travelInFlight: Set<String> = []
    /// Kept until they answer.
    @ObservationIgnored private var searches: [String: MKLocalSearch] = [:]
    @ObservationIgnored private var etaRequests: [String: MKDirections] = [:]
    @ObservationIgnored private var locatedRequestedAt: Date?

    /// How often what's shown is worked out again.
    private static let tickInterval: Duration = .seconds(15)
    /// Calendar's database is read again this often, besides when it says
    /// it changed.
    private static let refetchInterval: TimeInterval = 5 * 60
    /// How long before it starts an event shows.
    static let upcomingLead: TimeInterval = 15 * 60
    /// And a meeting, with nothing to get ready for.
    static let meetingLead: TimeInterval = 5 * 60
    /// How long a meeting shows as starting, with the button to join,
    /// before it's just on.
    private static let startingWindow: TimeInterval = 5 * 60
    /// Zoom's app, which joins from its own link without a browser tab.
    private static let zoomBundleIdentifier = "us.zoom.xos"
    /// How long before the time to leave an event shows, when the drive is
    /// longer than that.
    private static let leaveLead: TimeInterval = 10 * 60
    /// Time to park and walk in.
    static let leaveBuffer: TimeInterval = 2 * 60
    /// The next event follows straight on if it starts within this of the
    /// end.
    private static let backToBackGap: TimeInterval = 10 * 60
    /// Longer timed events, like a conference blocked out across days,
    /// don't get a ring.
    private static let maxDuringLength: TimeInterval = 8 * 60 * 60
    /// All-day events and birthdays show from then, the first time you're
    /// at the Mac.
    private static let morningHour = 5
    /// And the heads-up for an early start from then.
    private static let eveningHour = 21
    /// An event before this hour tomorrow is an early start.
    private static let earlyStartHour = 9
    /// How long a heads-up stays before it leaves.
    private static let headsUpDuration: Duration = .seconds(60)
    /// Events starting within this get a driving time.
    private static let travelLookAhead: TimeInterval = 3 * 60 * 60
    private static let travelRefreshInterval: TimeInterval = 5 * 60
    /// Further than this is a trip, not a drive.
    private static let maxTravelTime: TimeInterval = 3 * 60 * 60
    /// A location older than this is asked for again.
    private static let locationLifetime: TimeInterval = 10 * 60
    private static let searchRadius: CLLocationDistance = 300_000

    var isShown: Bool {
        activity != nil || isAgendaOpen
    }

    // MARK: - Turning on

    /// Asks for full access to Calendar the first time it's turned on.
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
        location.onChange = { [weak self] in
            self?.locationChanged()
        }
        refreshPermissions()
        if access == .notDetermined {
            requestAccess()
        }
    }

    /// Turned off: nothing more shows.
    func stop() {
        let wasShown = isShown
        ticking?.cancel()
        ticking = nil
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        storeObserver = nil
        events = []
        fetchedAt = nil
        dismissed = []
        headsUp = nil
        headsUpTimer?.cancel()
        leaving?.cancel()
        isHeadsUpDue = false
        leavingFor = []
        travelTimes = [:]
        travelFetchedAt = [:]
        destinations = [:]
        today = []
        isAgendaOpen = false
        activity = nil
        if wasShown {
            onEvent?(.ended)
        }
    }

    /// When the menu bar opens: access may have been granted or taken
    /// away in System Settings since.
    func refreshPermissions() {
        let previous = access
        access = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        // However it was granted: at the prompt or in System Settings.
        if access == .granted, previous != .granted {
            store = EKEventStore()
        }
        refreshLocationAccess()
        if isEnabled, access == .granted, ticking == nil {
            begin()
        } else if access != .granted, ticking != nil {
            stop()
        }
    }

    private func requestAccess() {
        // Called back on any queue.
        store.requestFullAccessToEvents { @Sendable [weak self] _, _ in
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
        SystemSettings.openPrivacy("Privacy_Calendars")
    }

    static func openLocationSettings() {
        SystemSettings.openPrivacy("Privacy_LocationServices")
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

    // MARK: - Calendars

    func isIncluded(_ calendar: CalendarChoice) -> Bool {
        !excludedCalendars.contains(calendar.id)
    }

    func setIncluded(_ calendar: CalendarChoice, _ included: Bool) {
        if included {
            excludedCalendars.remove(calendar.id)
        } else {
            excludedCalendars.insert(calendar.id)
        }
        UserDefaults.standard.set(Array(excludedCalendars), forKey: Self.excludedKey)
        reload()
    }

    /// Asks where you are the first time it's turned on.
    func setLeaveTimeEnabled(_ enabled: Bool) {
        isLeaveTimeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.leaveTimeKey)
        if enabled, location.status == .notDetermined {
            location.requestAccess()
        }
        if !enabled {
            travelTimes = [:]
            travelFetchedAt = [:]
            leavingFor = []
        }
        refreshLocationAccess()
        update()
    }

    private func refreshLocationAccess() {
        locationAccess = switch location.status {
        case .authorizedAlways: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private var canUseLocation: Bool {
        isLeaveTimeEnabled && locationAccess == .granted
    }

    // MARK: - Reading events

    private func tick() {
        let now = Date.now
        let isStale = fetchedAt.map { now.timeIntervalSince($0) > Self.refetchInterval || !Calendar.current.isDate($0, inSameDayAs: now) } ?? true
        if isStale {
            reload()
        } else {
            update()
        }
    }

    /// From the start of today to the end of tomorrow, for the heads-up
    /// the night before.
    private func reload() {
        guard access == .granted else { return }
        let all = store.calendars(for: .event)
        calendars = all
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        let included = all.filter { !excludedCalendars.contains($0.calendarIdentifier) }
        let startOfToday = Calendar.current.startOfDay(for: .now)
        if !included.isEmpty, let end = Calendar.current.date(byAdding: .day, value: 2, to: startOfToday) {
            let predicate = store.predicateForEvents(withStart: startOfToday, end: end, calendars: included)
            events = store.events(matching: predicate)
                .compactMap(Self.event(from:))
                .sorted { $0.start < $1.start }
        } else {
            events = []
        }
        fetchedAt = .now
        // Only what could still show.
        dismissed = dismissed.filter { key in events.contains { key.hasPrefix($0.id + "@") } }
        leavingFor = leavingFor.filter { id in events.contains { $0.id == id } }
        update()
    }

    private static func event(from event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate,
              event.status != .canceled, !isDeclined(event) else { return nil }
        let calendar: EKCalendar? = event.calendar
        let videoLink = VideoLink.find(in: [event.url?.absoluteString, event.location, event.notes])
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let geo = event.structuredLocation?.geoLocation?.coordinate
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CalendarEvent(
            id: "\(event.calendarItemIdentifier)@\(start.timeIntervalSinceReferenceDate)",
            eventIdentifier: event.eventIdentifier,
            title: title.isEmpty ? "New Event" : title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            // A meeting's location is often just its link.
            location: location?.isEmpty == false && !(location ?? "").contains("://") ? location : nil,
            coordinate: geo.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
            calendarTitle: calendar?.title ?? "",
            color: calendar?.color.map { Color(nsColor: $0) } ?? .calendarEvent,
            isBirthday: calendar?.type == .birthday,
            birthdayContactID: event.birthdayContactIdentifier,
            videoLink: videoLink,
            attendees: videoLink == nil ? [] : attendees(of: event),
            isRecurring: event.hasRecurrenceRules,
            occurrenceDate: event.occurrenceDate
        )
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } == true
    }

    /// The organizer first, then everyone else invited, but not you, the
    /// rooms booked, or those who declined.
    private static func attendees(of event: EKEvent) -> [String] {
        let people = ([event.organizer].compactMap { $0 } + (event.attendees ?? []))
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource && $0.participantStatus != .declined }
        var seen = Set<URL>()
        return people.compactMap { person in
            guard seen.insert(person.url).inserted else { return nil }
            return displayName(of: person)
        }
    }

    /// Their name, or the start of their email address without one.
    private static func displayName(of person: EKParticipant) -> String? {
        if let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.contains("@") {
            return name
        }
        let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
        let local = address.split(separator: "@").first.map(String.init)?.removingPercentEncoding ?? ""
        return local.isEmpty ? nil : local
    }

    // MARK: - What shows

    /// When to leave, from the drive there, once it's known.
    func leaveAt(_ event: CalendarEvent) -> Date? {
        guard canUseLocation, let travel = travelTimes[event.id] else { return nil }
        return event.start.addingTimeInterval(-travel - Self.leaveBuffer)
    }

    func travelTime(_ event: CalendarEvent) -> TimeInterval? {
        canUseLocation ? travelTimes[event.id] : nil
    }

    /// Time to leave first, then what's coming up, then what's on now. A
    /// heads-up only shows while none of those do.
    private func update() {
        guard isEnabled, access == .granted else { return }
        let now = Date.now
        let timed = timedActivity(at: now)
        // Only once it can show, so it doesn't use up its day, or its
        // time, behind an event.
        if headsUp == nil, timed == nil {
            checkForHeadsUp(at: now)
        }
        if let timed, timed.phase == .leave {
            leavingFor.insert(timed.event.id)
        }
        let previousKey = activity?.key
        let current = timed ?? headsUp.flatMap { dismissed.contains($0.key) ? nil : $0 }
        let needsYou = current?.phase == .leave || current?.phase == .starting
        if needsYou, current?.key != previousKey {
            // The notch opens on the time to leave, or the meeting, not the
            // rest of the day.
            isAgendaOpen = false
        }
        if current != activity {
            activity = current
        }
        let agenda = agenda(at: now)
        if agenda != today {
            today = agenda
        }
        refreshTravel(at: now)

        guard current?.key != previousKey else { return }
        if current != nil {
            onEvent?(needsYou ? .needsYou : .started)
        } else if !isAgendaOpen {
            onEvent?(.ended)
        }
    }

    private func timedActivity(at now: Date) -> Activity? {
        let timed = events.filter { !$0.isAllDay }

        func first(_ phase: Phase, of events: [CalendarEvent]) -> Activity? {
            events.lazy
                .map { Activity(phase: phase, event: $0) }
                .first { !self.dismissed.contains($0.key) }
        }

        // Meetings have no drive, so never a time to leave.
        let leaving = timed.filter { event in
            guard !event.isMeeting, now < event.start else { return false }
            if leavingFor.contains(event.id) { return true }
            guard let leaveAt = leaveAt(event) else { return false }
            return now >= leaveAt
        }
        if let activity = first(.leave, of: leaving) {
            return activity
        }
        let starting = timed.filter { event in
            event.isMeeting && now >= event.start && now < min(event.end, event.start.addingTimeInterval(Self.startingWindow))
        }
        if let activity = first(.starting, of: starting) {
            return activity
        }
        let upcoming = timed.filter { event in
            let showFrom = event.isMeeting
                ? event.start.addingTimeInterval(-Self.meetingLead)
                : min(
                    event.start.addingTimeInterval(-Self.upcomingLead),
                    leaveAt(event)?.addingTimeInterval(-Self.leaveLead) ?? .distantFuture
                )
            return now >= showFrom && now < event.start
        }
        if let activity = first(.upcoming, of: upcoming) {
            return activity
        }
        let during = timed
            .filter { now >= $0.start && now < $0.end && $0.end.timeIntervalSince($0.start) <= Self.maxDuringLength }
            .sorted { $0.end < $1.end }
        if var activity = first(.during, of: during) {
            let event = activity.event
            activity.next = timed.first {
                $0.id != event.id && $0.start > event.start && $0.start <= event.end.addingTimeInterval(Self.backToBackGap)
            }
            return activity
        }
        return nil
    }

    /// All-day events and birthdays once each morning, the first time
    /// you're at the Mac, and a heads-up at 9 PM for an event before 9 AM
    /// tomorrow. Each day only once, even when there's nothing to say.
    private func checkForHeadsUp(at now: Date) {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let day = Self.dayStamp(now)
        let defaults = UserDefaults.standard
        let startOfToday = calendar.startOfDay(for: now)
        guard hour >= Self.morningHour, Self.isAtTheMac,
              let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return }

        if hour < Self.eveningHour {
            guard defaults.string(forKey: Self.allDayShownKey) != day else { return }
            defaults.set(day, forKey: Self.allDayShownKey)
            let allDay = events
                .filter { $0.isAllDay && $0.start < startOfTomorrow && $0.end > startOfToday }
                .sorted { $0.isBirthday && !$1.isBirthday }
            guard let first = allDay.first else { return }
            showHeadsUp(Activity(phase: .allDay, event: first, moreCount: allDay.count - 1, age: age(on: first)))
        } else {
            guard defaults.string(forKey: Self.tomorrowShownKey) != day,
                  let early = calendar.date(byAdding: .hour, value: Self.earlyStartHour, to: startOfTomorrow) else { return }
            defaults.set(day, forKey: Self.tomorrowShownKey)
            guard let first = events.first(where: { !$0.isAllDay && $0.start >= startOfTomorrow && $0.start < early }) else { return }
            showHeadsUp(Activity(phase: .tomorrow, event: first))
        }
    }

    private func showHeadsUp(_ activity: Activity) {
        headsUp = activity
        isHeadsUpDue = false
        headsUpTimer?.cancel()
        headsUpTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.headsUpDuration)
            guard !Task.isCancelled, let self else { return }
            self.isHeadsUpDue = true
            self.leaveIfDue()
        }
    }

    /// Input in the last minute: someone's at the Mac, not just the Mac
    /// awake.
    private static var isAtTheMac: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 60
    }

    private static func dayStamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// Only when Contacts access was already given for Message: the
    /// morning's heads-up never asks for it.
    private func age(on event: CalendarEvent) -> Int? {
        guard event.isBirthday, let contactID = event.birthdayContactID,
              CNContactStore.authorizationStatus(for: .contacts) == .authorized,
              let contact = try? contacts.unifiedContact(withIdentifier: contactID, keysToFetch: [CNContactBirthdayKey as CNKeyDescriptor]),
              let year = contact.birthday?.year else { return nil }
        let age = Calendar.current.component(.year, from: event.start) - year
        return age > 0 ? age : nil
    }

    private func agenda(at now: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return [] }
        let allDay = events.filter { $0.isAllDay && $0.start < startOfTomorrow && $0.end > startOfToday }
        let timed = events.filter { !$0.isAllDay && $0.start < startOfTomorrow && $0.end > now }
        return allDay + timed
    }

    // MARK: - Time to leave

    /// Driving times for the next few hours' events, looked up again every
    /// few minutes for the traffic.
    private func refreshTravel(at now: Date) {
        guard canUseLocation else { return }
        let due = events.filter { event in
            guard !event.isAllDay, !event.isMeeting, event.location != nil || event.coordinate != nil,
                  event.start > now, event.start.timeIntervalSince(now) < Self.travelLookAhead,
                  !travelInFlight.contains(event.id) else { return false }
            return travelFetchedAt[event.id].map { now.timeIntervalSince($0) > Self.travelRefreshInterval } ?? true
        }
        guard !due.isEmpty else { return }
        guard let here = location.coordinate, let locatedAt = location.locatedAt,
              now.timeIntervalSince(locatedAt) < Self.locationLifetime else {
            // Answers through `locationChanged`.
            if locatedRequestedAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                locatedRequestedAt = now
                location.locate()
            }
            return
        }
        for event in due {
            fetchTravel(to: event, from: here)
        }
    }

    private func locationChanged() {
        refreshLocationAccess()
        update()
    }

    private func fetchTravel(to event: CalendarEvent, from here: GeoCoordinate) {
        let id = event.id
        travelInFlight.insert(id)
        travelFetchedAt[id] = .now
        if let destination = event.coordinate ?? destinations[id] {
            fetchETA(for: id, from: here, to: destination)
            return
        }
        guard let address = event.location else {
            travelInFlight.remove(id)
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.region = MKCoordinateRegion(
            center: here.location.coordinate,
            latitudinalMeters: Self.searchRadius,
            longitudinalMeters: Self.searchRadius
        )
        let search = MKLocalSearch(request: request)
        searches[id] = search
        search.start { @Sendable [weak self] response, _ in
            let found = response?.mapItems.first.map {
                GeoCoordinate(latitude: $0.location.coordinate.latitude, longitude: $0.location.coordinate.longitude)
            }
            Task { @MainActor in
                guard let self else { return }
                self.searches[id] = nil
                guard let found else {
                    self.travelInFlight.remove(id)
                    return
                }
                self.destinations[id] = found
                self.fetchETA(for: id, from: here, to: found)
            }
        }
    }

    private func fetchETA(for id: String, from here: GeoCoordinate, to destination: GeoCoordinate) {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: here.location, address: nil)
        request.destination = MKMapItem(location: destination.location, address: nil)
        request.transportType = .automobile
        request.departureDate = .now
        let directions = MKDirections(request: request)
        etaRequests[id] = directions
        directions.calculateETA { @Sendable [weak self] response, _ in
            let seconds = response?.expectedTravelTime
            Task { @MainActor in
                guard let self else { return }
                self.etaRequests[id] = nil
                self.travelInFlight.remove(id)
                // A failed lookup keeps the last good time.
                if let seconds, seconds < Self.maxTravelTime {
                    self.travelTimes[id] = seconds
                }
                self.update()
            }
        }
    }

    // MARK: - Actions

    /// From Settings › Activities, or the tile of the event shown.
    func showToday() {
        leaving?.cancel()
        today = agenda(at: .now)
        isAgendaOpen = true
    }

    /// The tile switches between the event and the rest of the day.
    func toggleToday() {
        if isAgendaOpen {
            isAgendaOpen = false
        } else {
            showToday()
        }
    }

    func dismiss() {
        guard let activity else {
            closeToday()
            return
        }
        dismissed.insert(activity.key)
        if activity.phase == .leave {
            // Not back to the minutes until it starts.
            dismissed.insert(Activity(phase: .upcoming, event: activity.event).key)
        }
        if activity.phase == .starting {
            // Not joining, so not the time left either. Join keeps it.
            dismissed.insert(Activity(phase: .during, event: activity.event).key)
        }
        if activity.key == headsUp?.key {
            headsUp = nil
            headsUpTimer?.cancel()
        }
        isAgendaOpen = false
        update()
    }

    private func closeToday() {
        guard isAgendaOpen else { return }
        isAgendaOpen = false
        if activity == nil {
            onEvent?(.ended)
        }
    }

    /// A heads-up that has had its time, and the rest of the day once the
    /// notch closes, leave unless the notch is open or under the cursor;
    /// then they wait to be asked again.
    func leaveIfDue(after delay: Duration = .zero) {
        guard (isHeadsUpDue && headsUp != nil) || isAgendaOpen else { return }
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isInUse() else { return }
            if self.isHeadsUpDue {
                self.isHeadsUpDue = false
                self.headsUp = nil
            }
            self.closeToday()
            self.update()
        }
    }

    /// Maps, with driving directions from where you are.
    func openDirections() {
        guard let event = activity?.event else { return }
        let destination = event.coordinate.map { "\($0.latitude),\($0.longitude)" } ?? event.location ?? ""
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        guard !destination.isEmpty,
              let encoded = destination.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "maps://?daddr=\(encoded)&dirflg=d") else { return }
        NSWorkspace.shared.open(url)
        dismiss()
    }

    /// The meeting's link: Zoom's straight in its app when it's there,
    /// the rest in the browser, which hands over to their apps. Once
    /// joined, it doesn't ask again as it starts; the time left still
    /// shows once it's on.
    func joinMeeting() {
        guard let activity, let link = activity.event.videoLink else { return }
        NSWorkspace.shared.open(Self.appURL(for: link) ?? link.url)
        dismissed.insert(Activity(phase: .upcoming, event: activity.event).key)
        dismissed.insert(Activity(phase: .starting, event: activity.event).key)
        isAgendaOpen = false
        update()
    }

    /// zoommtg://zoom.us/join?confno=…&pwd=… for a zoom.us/j/… link, when
    /// Zoom is installed.
    private static func appURL(for link: VideoLink) -> URL? {
        guard link.service == "Zoom",
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: zoomBundleIdentifier) != nil,
              let components = URLComponents(url: link.url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.path.split(separator: "/")
        guard let index = parts.firstIndex(of: "j"), parts.indices.contains(index + 1) else { return nil }
        var app = URLComponents()
        app.scheme = "zoommtg"
        app.host = "zoom.us"
        app.path = "/join"
        app.queryItems = [URLQueryItem(name: "confno", value: String(parts[index + 1]))]
            + (components.queryItems?.filter { $0.name == "pwd" } ?? [])
        return app.url
    }

    func openInCalendar() {
        open(activity?.event)
        dismiss()
    }

    /// The event in Calendar, from the rest of the day, or Calendar itself
    /// without one. Calendar in front puts the notch away by itself.
    func open(_ event: CalendarEvent?) {
        // Otherwise just Calendar.
        if event.flatMap(Self.calendarURL(for:)).map({ NSWorkspace.shared.open($0) }) != true {
            Self.openApp(Self.appBundleIdentifier)
        }
    }

    /// Calendar's link to the event. Every occurrence of a repeating event
    /// shares its identifier, so the occurrence's date goes before it, or
    /// Calendar shows the first: in UTC for a timed event, and as the time
    /// on the clock for an all-day one, which has no time zone.
    private static func calendarURL(for event: CalendarEvent) -> URL? {
        guard let id = event.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        guard event.isRecurring, let date = event.occurrenceDate else {
            return URL(string: "ical://ekevent/\(id)?method=show&options=more")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if event.isAllDay {
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        } else {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        }
        return URL(string: "ical://ekevent/\(formatter.string(from: date))/\(id)?method=show&options=more")
    }

    /// Messages, to the person whose birthday it is. Contacts access is
    /// asked for here, the first time, since that's what it's for.
    func messageBirthdayPerson() {
        let contactID = activity?.event.birthdayContactID
        dismiss()
        guard let contactID else {
            Self.openApp("com.apple.MobileSMS")
            return
        }
        // Called back on any queue.
        contacts.requestAccess(for: .contacts) { @Sendable [weak self] granted, _ in
            Task { @MainActor in
                self?.openMessages(to: granted ? contactID : nil)
            }
        }
    }

    private func openMessages(to contactID: String?) {
        let keys = [CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
        let contact = contactID.flatMap { try? contacts.unifiedContact(withIdentifier: $0, keysToFetch: keys) }
        let address = contact?.phoneNumbers.first?.value.stringValue ?? contact?.emailAddresses.first.map { $0.value as String }
        if let address,
           let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "imessage:\(encoded)") {
            NSWorkspace.shared.open(url)
        } else {
            Self.openApp("com.apple.MobileSMS")
        }
    }

    private static func openApp(_ bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Where you are, for the drive to an event. Only asked for once Show When
/// to Leave is turned on.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    var onChange: (() -> Void)?
    private(set) var coordinate: GeoCoordinate?
    private(set) var locatedAt: Date?
    private let manager = CLLocationManager()

    var status: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func requestAccess() {
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    /// Once; the answer comes through `onChange`.
    func locate() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last?.coordinate else { return }
        let coordinate = GeoCoordinate(latitude: last.latitude, longitude: last.longitude)
        Task { @MainActor in
            self.coordinate = coordinate
            self.locatedAt = .now
            self.onChange?()
        }
    }

    /// Required with `requestLocation`. The next refresh asks again.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}

extension Color {
    /// The design's purple for events, and for the day's agenda.
    static let calendarEvent = Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255)
    /// The design's pink for birthdays.
    static let calendarBirthday = Color(red: 1, green: 55 / 255, blue: 95 / 255)
    /// The design's blue for meetings.
    static let calendarMeeting = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    /// The design's green as a meeting starts, and for Join.
    static let calendarJoin = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    /// Dark green on Join.
    static let calendarJoinLabel = Color(red: 6 / 255, green: 33 / 255, blue: 15 / 255)
}

#if DEBUG
extension CalendarMonitor {
    /// Shows what's given and stays that way, for SwiftUI previews.
    static func preview(
        _ activity: Activity?,
        today: [CalendarEvent] = [],
        travelTimes: [String: TimeInterval] = [:],
        isAgendaOpen: Bool = false
    ) -> CalendarMonitor {
        let monitor = CalendarMonitor()
        monitor.activity = activity
        monitor.today = today
        monitor.travelTimes = travelTimes
        monitor.isLeaveTimeEnabled = !travelTimes.isEmpty
        monitor.locationAccess = travelTimes.isEmpty ? .notDetermined : .granted
        monitor.isAgendaOpen = isAgendaOpen
        return monitor
    }
}
#endif
