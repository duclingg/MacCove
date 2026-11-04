//
//  CalendarViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import SwiftUI

/// Birthdays in pink, everything else in its calendar's colour.
private func eventTint(_ event: CalendarEvent) -> Color {
    event.isBirthday ? .calendarBirthday : event.color
}

/// A car while it's time to leave, a gift for a birthday, otherwise the
/// calendar.
private func symbol(for activity: CalendarMonitor.Activity?) -> String {
    switch activity?.phase {
    case .leave?: "car"
    case .allDay? where activity?.event.isBirthday == true: "gift"
    default: "calendar"
    }
}

/// Dark text on light calendar colours like yellow, white on the rest.
private func labelColor(on background: Color) -> Color {
    guard let rgb = NSColor(background).usingColorSpace(.sRGB) else { return .white }
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return luminance > 0.6 ? Color(red: 20 / 255, green: 20 / 255, blue: 19 / 255) : .white
}

/// "3:00 PM".
private func clockTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

private let timeRangeFormatter: DateIntervalFormatter = {
    let formatter = DateIntervalFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

/// "3:00 – 3:45 PM".
private func timeRange(_ event: CalendarEvent) -> String {
    timeRangeFormatter.string(from: event.start, to: event.end)
}

/// Whole minutes, rounded up, so "1 min" lasts until it starts.
private func minutes(until date: Date, from now: Date) -> Int {
    max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
}

/// "12 min", "1 hr 20 min", "2 hr".
private func durationText(minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes) min" }
    let rest = minutes % 60
    return rest == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(rest) min"
}

/// "12 min", then "2 hr", for the pill.
private func shortDurationText(minutes: Int) -> String {
    minutes < 100 ? "\(minutes) min" : "\(minutes / 60) hr"
}

private func elapsedFraction(_ event: CalendarEvent, at now: Date) -> Double {
    let length = event.end.timeIntervalSince(event.start)
    guard length > 0 else { return 1 }
    return min(1, max(0, now.timeIntervalSince(event.start) / length))
}

/// How much of today is still to come: everything but what's on now.
private func moreCount(_ today: [CalendarEvent], at now: Date) -> Int {
    today.filter { $0.isAllDay || $0.start > now }.count
}

private struct CalendarGlyph: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (size * 0.82).rounded(), weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The time gone, in the calendar's colour, over a dim track.
private struct CalendarRing: View {
    let progress: Double
    /// Across the outside of the stroke.
    let diameter: CGFloat
    let lineWidth: CGFloat
    let color: Color
    var trackOpacity = 0.2

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(trackOpacity), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The calendar in the left wing, in the event's colour. In the right:
/// minutes until it starts, Leave when it's time, the time gone as a ring
/// while it's on, Today for all-day events, the start time the night
/// before, or how much more there is today.
struct CalendarCompactView: View {
    let calendar: CalendarMonitor
    let notchSize: CGSize

    private static let trailingFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    /// Between the text and the notch, as the artwork has.
    private static let notchGap: CGFloat = 12

    /// Wide enough for the text on the right, the same on both sides so
    /// the notch stays in the middle. Measured with room for two-digit
    /// minutes, so it doesn't change size as they count down.
    static func width(for calendar: CalendarMonitor, notch: CGSize) -> CGFloat {
        guard let text = widestTrailingText(calendar) else { return NotchViewModel.compactWidth(notch: notch) }
        let layout = CompactLayout(notch: notch)
        let textWidth = (text as NSString).size(withAttributes: [.font: trailingFont]).width.rounded(.up)
        return notch.width + (layout.sideInset + max(layout.artSize, textWidth) + notchGap) * 2
    }

    private static func widestTrailingText(_ calendar: CalendarMonitor) -> String? {
        guard let activity = calendar.activity else {
            return calendar.isAgendaOpen ? "\(moreCount(calendar.today, at: .now)) more" : nil
        }
        switch activity.phase {
        case .upcoming: return "88 min"
        case .leave: return "Leave"
        case .during: return nil
        case .allDay: return "Today"
        case .tomorrow: return clockTime(activity.event.start)
        }
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let activity = calendar.activity

        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 0) {
                CalendarGlyph(symbol: symbol(for: activity), color: activity.map { eventTint($0.event) } ?? .calendarEvent, size: layout.artSize)
                Spacer(minLength: 0)
                trailing(activity, at: context.date, size: layout.artSize)
            }
            .font(.system(size: 15, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, layout.sideInset)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityDescription(calendar, at: context.date))
            .accessibilityAddTraits(.isButton)
        }
        .frame(width: Self.width(for: calendar, notch: notchSize), height: notchSize.height)
    }

    @ViewBuilder
    private func trailing(_ activity: CalendarMonitor.Activity?, at now: Date, size: CGFloat) -> some View {
        if let activity {
            switch activity.phase {
            case .upcoming:
                Text(shortDurationText(minutes: minutes(until: activity.event.start, from: now)))
            case .leave:
                Text("Leave")
                    .foregroundStyle(eventTint(activity.event))
            case .during:
                CalendarRing(progress: elapsedFraction(activity.event, at: now), diameter: 20, lineWidth: 3, color: eventTint(activity.event))
                    .frame(width: size, height: size)
            case .allDay:
                Text("Today")
            case .tomorrow:
                Text(clockTime(activity.event.start))
            }
        } else {
            Text("\(moreCount(calendar.today, at: now)) more")
        }
    }

    private static func accessibilityDescription(_ calendar: CalendarMonitor, at now: Date) -> String {
        guard let activity = calendar.activity else {
            return "Today, \(moreCount(calendar.today, at: now)) more events"
        }
        let event = activity.event
        switch activity.phase {
        case .upcoming: return "\(event.title) in \(durationText(minutes: minutes(until: event.start, from: now)))"
        case .leave: return "Time to leave for \(event.title)"
        case .during: return "\(event.title), \(durationText(minutes: minutes(until: event.end, from: now))) left"
        case .allDay: return "Today: \(event.title)"
        case .tomorrow: return "Tomorrow at \(clockTime(event.start)): \(event.title)"
        }
    }
}

/// The calendar in a bubble beside another activity: inside its ring while
/// the event is on, otherwise in the event's colour.
struct CalendarMinimalView: View {
    let calendar: CalendarMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)
        let activity = calendar.activity
        let color = activity.map { eventTint($0.event) } ?? .calendarEvent

        Group {
            if let activity, activity.phase == .during {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    ZStack {
                        CalendarRing(
                            progress: elapsedFraction(activity.event, at: context.date),
                            diameter: layout.ringDiameter,
                            lineWidth: layout.ringLineWidth,
                            color: color,
                            trackOpacity: 0.18
                        )
                        CalendarGlyph(symbol: "calendar", color: .white, size: (layout.ringDiameter * 0.55).rounded())
                    }
                }
            } else {
                CalendarGlyph(symbol: symbol(for: activity), color: color, size: layout.artSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity?.event.title ?? "Today")
        .accessibilityAddTraits(.isButton)
    }
}

/// Opened up. The event: when it is and where, when to leave or how long
/// is left, and buttons for what to do about it. Its tile switches to the
/// rest of the day, and back, where each event opens in Calendar.
struct CalendarExpandedView: View {
    let calendar: CalendarMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let barGap: CGFloat = 10
    private static let barHeight: CGFloat = 6
    private static let footerGap: CGFloat = 6
    private static let footerHeight: CGFloat = 16
    private static let listGap: CGFloat = 10
    private static let listPadding: CGFloat = 4
    private static let rowHeight: CGFloat = 40
    /// The rest of the day, as far as this; the subtitle counts them all.
    private static let maxRows = 5
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    private var isShowingToday: Bool {
        calendar.isAgendaOpen || calendar.activity == nil
    }

    static func bodyHeight(for calendar: CalendarMonitor) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        if calendar.isAgendaOpen || calendar.activity == nil {
            let rows = min(calendar.today.count, maxRows)
            if rows > 0 {
                height += listGap + listPadding * 2 + rowHeight * CGFloat(rows)
            }
        } else if calendar.activity?.phase == .during {
            height += barGap + barHeight + footerGap + footerHeight
        } else {
            height += chipsGap + chipHeight
        }
        return height
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(spacing: 0) {
                if isShowingToday {
                    today(at: context.date)
                } else if let activity = calendar.activity {
                    event(activity, at: context.date)
                }
            }
            .padding(.horizontal, NotchViewModel.expandedInset)
            .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
            .frame(width: NotchViewModel.expandedWidth, alignment: .top)
        }
    }

    // MARK: - The event

    @ViewBuilder
    private func event(_ activity: CalendarMonitor.Activity, at now: Date) -> some View {
        let color = eventTint(activity.event)
        header(
            symbol: symbol(for: activity),
            color: color,
            title: Self.title(activity),
            subtitle: subtitle(activity, at: now),
            big: big(activity, at: now),
            tileLabel: "Show Today"
        )
        if activity.phase == .during {
            progress(activity, color: color, at: now)
        } else {
            buttons(activity, color: color)
                .padding(.top, Self.chipsGap)
        }
    }

    /// The tile switches between the event and the rest of the day, or,
    /// with no event to go back to, opens Calendar.
    private func header(symbol: String, color: Color, title: String, subtitle: String, big: String?, tileLabel: String?) -> some View {
        HStack(spacing: 12) {
            Button {
                if tileLabel != nil {
                    calendar.toggleToday()
                } else {
                    calendar.open(nil)
                }
            } label: {
                tile(symbol: symbol, color: color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tileLabel ?? "Open Calendar")

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
                    .truncationMode(.tail)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if let big {
                Text(big)
                    .font(.system(size: 20, weight: .medium))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func tile(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The bar fills as it goes. Under it, the time left, and what's next
    /// when it follows straight on.
    private func progress(_ activity: CalendarMonitor.Activity, color: Color, at now: Date) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(color)
                            .frame(width: proxy.size.width * elapsedFraction(activity.event, at: now))
                    }
                }
                .frame(height: Self.barHeight)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text("\(durationText(minutes: minutes(until: activity.event.end, from: now))) left")
                Spacer(minLength: 0)
                if let next = activity.next {
                    Text("Next: \(next.title) at \(clockTime(next.start))")
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.islandSecondary)
            .lineLimit(1)
            .frame(height: Self.footerHeight)
            .padding(.top, Self.footerGap)
        }
        .padding(.top, Self.barGap)
    }

    @ViewBuilder
    private func buttons(_ activity: CalendarMonitor.Activity, color: Color) -> some View {
        let event = activity.event
        let hasPlace = event.location != nil || event.coordinate != nil

        HStack(spacing: 8) {
            chip("Dismiss") { calendar.dismiss() }
            switch activity.phase {
            case .upcoming where hasPlace, .leave where hasPlace:
                chip("Directions", background: color, foreground: labelColor(on: color)) { calendar.openDirections() }
            case .allDay where event.isBirthday:
                chip("Message", background: color, foreground: labelColor(on: color)) { calendar.messageBirthdayPerson() }
            default:
                chip("Open in Calendar", background: color, foreground: labelColor(on: color)) { calendar.openInCalendar() }
            }
        }
    }

    private func chip(
        _ label: String,
        background: Color = .white.opacity(0.12),
        foreground: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private static func title(_ activity: CalendarMonitor.Activity) -> String {
        switch activity.phase {
        case .leave: "Time to leave for \(activity.event.title)"
        case .tomorrow: "Tomorrow starts early"
        case .upcoming, .during, .allDay: activity.event.title
        }
    }

    /// "3:00 – 3:45 PM · 450 Sutter St", "18 min by car · there by 2:58
    /// PM", "Work · ends at 4:00 PM", "Today · turning 60 · from
    /// Contacts", "Flight to Austin · SFO Terminal 2".
    private func subtitle(_ activity: CalendarMonitor.Activity, at now: Date) -> String {
        let event = activity.event
        let place = event.location ?? event.calendarTitle
        switch activity.phase {
        case .upcoming:
            return [timeRange(event), place].filter { !$0.isEmpty }.joined(separator: " · ")
        case .leave:
            guard let travel = calendar.travelTime(event) else { return timeRange(event) }
            let drive = durationText(minutes: Int((travel / 60).rounded()))
            return "\(drive) by car · there by \(clockTime(now.addingTimeInterval(travel)))"
        case .during:
            let ends = "ends at \(clockTime(event.end))"
            return event.calendarTitle.isEmpty ? "Ends at \(clockTime(event.end))" : "\(event.calendarTitle) · \(ends)"
        case .allDay:
            var parts = ["Today"]
            if let age = activity.age {
                parts.append("turning \(age)")
            }
            parts.append(event.isBirthday ? "from Contacts" : event.calendarTitle)
            if activity.moreCount > 0 {
                parts.append("\(activity.moreCount) more")
            }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        case .tomorrow:
            return [event.title, place].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// On the right of the header: when to leave, or how long until it
    /// starts without a drive to go by, and the start time the night
    /// before.
    private func big(_ activity: CalendarMonitor.Activity, at now: Date) -> String? {
        let event = activity.event
        switch activity.phase {
        case .upcoming:
            if let leaveAt = calendar.leaveAt(event) {
                let left = minutes(until: leaveAt, from: now)
                return left > 0 ? "Leave in \(durationText(minutes: left))" : "Leave now"
            }
            return "in \(durationText(minutes: minutes(until: event.start, from: now)))"
        case .tomorrow:
            return clockTime(event.start)
        case .leave, .during, .allDay:
            return nil
        }
    }

    // MARK: - The rest of today

    @ViewBuilder
    private func today(at now: Date) -> some View {
        let events = calendar.today
        let more = moreCount(events, at: now)
        let date = now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let count = switch more {
        case 0: events.isEmpty ? "Nothing else today" : "Nothing after this"
        case 1: "1 more event"
        default: "\(more) more events"
        }

        header(
            symbol: "calendar",
            color: .calendarEvent,
            title: "Today",
            subtitle: "\(date) · \(count)",
            big: nil,
            tileLabel: calendar.activity.map { "Back to \($0.event.title)" }
        )
        if !events.isEmpty {
            VStack(spacing: 0) {
                ForEach(events.prefix(Self.maxRows)) { event in
                    row(event, at: now)
                }
            }
            .padding(.vertical, Self.listPadding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            .padding(.top, Self.listGap)
        }
    }

    /// Its calendar's colour as a stripe, what it is and where or which
    /// calendar, and when: All day, Now, or the start time. Opens the
    /// event in Calendar.
    private func row(_ event: CalendarEvent, at now: Date) -> some View {
        Button {
            calendar.open(event)
        } label: {
            rowContent(event, at: now)
        }
        .buttonStyle(CalendarRowStyle())
        .accessibilityHint("Opens in Calendar")
    }

    private func rowContent(_ event: CalendarEvent, at now: Date) -> some View {
        let color = eventTint(event)
        let isNow = !event.isAllDay && event.start <= now

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                Text(rowSubtitle(event))
                    .font(.system(size: 11))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(event.isAllDay ? "All day" : isNow ? "Now" : clockTime(event.start))
                .font(.system(size: 12, weight: isNow ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isNow ? color : Color.islandSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "450 Sutter St · leave at 2:40 PM", or the calendar it's in.
    private func rowSubtitle(_ event: CalendarEvent) -> String {
        guard let location = event.location else { return event.calendarTitle }
        guard let leaveAt = calendar.leaveAt(event) else { return location }
        return "\(location) · leave at \(clockTime(leaveAt))"
    }
}

/// A row of the day that lights up under the cursor and as it's clicked,
/// so it reads as something to click.
private struct CalendarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalendarRow(configuration: configuration)
    }

    private struct CalendarRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.06 : 0))
                        .padding(.horizontal, 4)
                )
                .onHover { isHovered = $0 }
        }
    }
}
