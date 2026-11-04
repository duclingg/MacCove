//
//  CalendarPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)
private let work = Color(red: 1, green: 159 / 255, blue: 10 / 255)
private let home = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)

private func event(
    _ title: String,
    startsIn minutes: Double,
    lasting length: Double = 45,
    location: String? = nil,
    calendar: String = "Personal",
    color: Color = .calendarEvent,
    isAllDay: Bool = false,
    isBirthday: Bool = false,
    videoLink: VideoLink? = nil,
    attendees: [String] = []
) -> CalendarEvent {
    let start = Date.now.addingTimeInterval(minutes * 60)
    return CalendarEvent(
        id: title,
        eventIdentifier: nil,
        title: title,
        start: start,
        end: start.addingTimeInterval(length * 60),
        isAllDay: isAllDay,
        location: location,
        coordinate: nil,
        calendarTitle: calendar,
        color: color,
        isBirthday: isBirthday,
        birthdayContactID: nil,
        videoLink: videoLink,
        attendees: attendees
    )
}

private let dentist = event("Dentist", startsIn: 15, location: "450 Sutter St")
private let deepWork = event("Deep work", startsIn: -42, lasting: 60, calendar: "Work", color: work)
private let birthday = event("Mom’s birthday", startsIn: -600, lasting: 24 * 60, calendar: "Birthdays", isAllDay: true, isBirthday: true)
private let flight = event("Flight to Austin", startsIn: 10 * 60, location: "SFO Terminal 2", color: Color(red: 10 / 255, green: 132 / 255, blue: 1))
private let dinner = event("Dinner with Sam", startsIn: 4 * 60, lasting: 90, location: "Nopa, Divisadero St", calendar: "Home", color: home)
private let zoom = VideoLink(url: URL(string: "https://zoom.us/j/123456789")!, service: "Zoom")
private let team = ["Maya Kim", "Jordan Lee", "Ari Rao", "Sam Ortiz", "Alex Chen"]
private let designReview = event("Design review", startsIn: 5, lasting: 30, calendar: "Work", color: work, videoLink: zoom, attendees: team)
private let designReviewStarting = event("Design review", startsIn: -1, lasting: 30, calendar: "Work", color: work, videoLink: zoom, attendees: team)
private let designReviewOn = event("Design review", startsIn: -18, lasting: 30, calendar: "Work", color: work, videoLink: zoom, attendees: team)
/// An 8-minute drive to a 15-minutes-away event: leave in 5.
private let dentistDrive: [String: TimeInterval] = ["Dentist": 8 * 60]

private func compact(_ calendar: CalendarMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: CalendarCompactView.width(for: calendar, notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        CalendarCompactView(calendar: calendar, notchSize: notch)
    }
}

private func expanded(_ calendar: CalendarMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + CalendarExpandedView.bodyHeight(for: calendar)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        // As the notch shows it, with Mirror as a meeting starts.
        CalendarExpandedView(calendar: calendar, notchHeight: notch.height, openMirror: {})
    }
}

#Preview("Coming up") {
    compact(.preview(.init(phase: .upcoming, event: dentist)))
}

#Preview("Coming up, expanded") {
    expanded(.preview(.init(phase: .upcoming, event: dentist), travelTimes: dentistDrive))
}

#Preview("Time to leave") {
    compact(.preview(.init(phase: .leave, event: dentist), travelTimes: ["Dentist": 13 * 60]))
}

#Preview("Time to leave, expanded") {
    expanded(.preview(.init(phase: .leave, event: dentist), travelTimes: ["Dentist": 13 * 60]))
}

#Preview("During") {
    compact(.preview(.init(phase: .during, event: deepWork)))
}

#Preview("During, expanded") {
    expanded(.preview(.init(phase: .during, event: deepWork, next: event("Dentist", startsIn: 20, location: "450 Sutter St"))))
}

#Preview("Birthday, expanded") {
    expanded(.preview(.init(phase: .allDay, event: birthday, age: 60)))
}

#Preview("Early start tomorrow, expanded") {
    expanded(.preview(.init(phase: .tomorrow, event: flight)))
}

#Preview("Today") {
    compact(.preview(nil, today: [birthday, deepWork, dentist, dinner], isAgendaOpen: true))
}

#Preview("Today, expanded") {
    expanded(.preview(
        .init(phase: .during, event: deepWork),
        today: [birthday, deepWork, dentist, dinner],
        travelTimes: dentistDrive,
        isAgendaOpen: true
    ))
}
#Preview("Meeting coming up") {
    compact(.preview(.init(phase: .upcoming, event: designReview)))
}

#Preview("Meeting coming up, expanded") {
    expanded(.preview(.init(phase: .upcoming, event: designReview)))
}

#Preview("Meeting starting") {
    compact(.preview(.init(phase: .starting, event: designReviewStarting)))
}

#Preview("Meeting starting, expanded") {
    expanded(.preview(.init(phase: .starting, event: designReviewStarting)))
}

#Preview("Meeting on, expanded") {
    expanded(.preview(.init(
        phase: .during,
        event: designReviewOn,
        next: event("1:1 with Alex", startsIn: 12, lasting: 30, calendar: "Work", color: work, videoLink: zoom)
    )))
}
#endif
