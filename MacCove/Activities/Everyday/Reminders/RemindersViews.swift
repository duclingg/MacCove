//
//  RemindersViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI

/// "5:00 PM".
private func clockTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// "Due today at 5:00 PM", "Due yesterday at 9:00 AM", "Due Monday at
/// 6:30 PM". Overdue ones go back at most six days, so the weekday is
/// never this week's and last week's at once.
private func dueText(_ reminder: ReminderItem) -> String {
    let calendar = Calendar.current
    let time = clockTime(reminder.due)
    if calendar.isDateInToday(reminder.due) {
        return "Due today at \(time)"
    }
    if calendar.isDateInYesterday(reminder.due) {
        return "Due yesterday at \(time)"
    }
    return "Due \(reminder.due.formatted(.dateTime.weekday(.wide))) at \(time)"
}

/// "Personal and Home", "Personal, Home, Work and 2 more".
private func listNames(_ reminders: [ReminderItem]) -> String {
    var seen: Set<String> = []
    let names = reminders.map(\.listTitle).filter { !$0.isEmpty && seen.insert($0).inserted }
    guard names.count > 3 else { return names.formatted(.list(type: .and)) }
    return "\(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more"
}

private struct ReminderGlyph: View {
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

/// The checklist in the left wing. In the right: Due, how many are left
/// to tick off, or a check once one is completed.
struct RemindersCompactView: View {
    let reminders: RemindersMonitor
    let notchSize: CGSize

    private static let trailingFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    /// Between the text and the notch, as the artwork has.
    private static let notchGap: CGFloat = 12

    /// Wide enough for the text on the right, the same on both sides so
    /// the notch stays in the middle. Measured with room for a two-digit
    /// count, so it doesn't change size as they're ticked off.
    static func width(for reminders: RemindersMonitor, notch: CGSize) -> CGFloat {
        let text: String? = switch reminders.phase {
        case .due?: "Due"
        case .many?: "88"
        case .completed?, nil: nil
        }
        guard let text else { return NotchViewModel.compactWidth(notch: notch) }
        let layout = CompactLayout(notch: notch)
        let textWidth = (text as NSString).size(withAttributes: [.font: trailingFont]).width.rounded(.up)
        return notch.width + (layout.sideInset + max(layout.artSize, textWidth) + notchGap) * 2
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)

        HStack(spacing: 0) {
            ReminderGlyph(symbol: "checklist", color: .reminder, size: layout.artSize)
            Spacer(minLength: 0)
            trailing(size: layout.artSize)
        }
        .font(.system(size: 15, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, layout.sideInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .frame(width: Self.width(for: reminders, notch: notchSize), height: notchSize.height)
    }

    @ViewBuilder
    private func trailing(size: CGFloat) -> some View {
        switch reminders.phase {
        case .due?:
            Text("Due")
                .foregroundStyle(Color.reminder)
        case .many? where !reminders.remaining.isEmpty:
            Text("\(reminders.remaining.count)")
                .foregroundStyle(Color.reminder)
        case .many?, .completed?:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.reminderDone)
                .frame(width: size, height: size)
        case nil:
            EmptyView()
        }
    }

    private var accessibilityDescription: String {
        switch reminders.phase {
        case .due?:
            guard let reminder = reminders.due.first else { return "Reminders" }
            return "Reminder: \(reminder.title), \(dueText(reminder))"
        case .many?:
            let count = reminders.remaining.count
            return count == 1 ? "1 reminder due today" : "\(count) reminders due today"
        case .completed?:
            return "Completed: \(reminders.completed?.title ?? "reminder")"
        case nil:
            return "Reminders"
        }
    }
}

/// The checklist in a bubble beside another activity, or the check as one
/// is completed.
struct RemindersMinimalView: View {
    let reminders: RemindersMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)
        let isCompleted = reminders.phase == .completed

        ReminderGlyph(
            symbol: isCompleted ? "checkmark" : "checklist",
            color: isCompleted ? .reminderDone : .reminder,
            size: layout.artSize
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCompleted ? "Completed" : "Reminders")
        .accessibilityAddTraits(.isButton)
    }
}

/// Opened up. The reminder due, with Snooze 1 Hour and Complete; the day's
/// list to tick off when several are due; or the one just completed. The
/// tile opens Reminders.
struct RemindersExpandedView: View {
    let reminders: RemindersMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let listGap: CGFloat = 10
    private static let listPadding: CGFloat = 4
    private static let rowHeight: CGFloat = 40
    /// The list, as far as this; the title counts them all.
    private static let maxRows = 5
    private static let bottomGap: CGFloat = 14
    /// The ring of a reminder not done yet.
    private static let ringColor = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.5)

    static func bodyHeight(for reminders: RemindersMonitor) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        switch reminders.phase {
        case .due?:
            height += chipsGap + chipHeight
        case .many?:
            let rows = min(reminders.rows.count, maxRows)
            if rows > 0 {
                height += listGap + listPadding * 2 + rowHeight * CGFloat(rows)
            }
        case .completed?, nil:
            break
        }
        return height
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(spacing: 0) {
                switch reminders.phase {
                case .due?:
                    if let reminder = reminders.due.first {
                        due(reminder)
                    }
                case .many?:
                    list(at: context.date)
                case .completed?:
                    header(title: "Completed", subtitle: reminders.completed?.title ?? "")
                case nil:
                    EmptyView()
                }
            }
            .padding(.horizontal, NotchViewModel.expandedInset)
            .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
            .frame(width: NotchViewModel.expandedWidth, alignment: .top)
        }
    }

    // MARK: - Header

    private func header(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Button {
                reminders.openReminders()
            } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.reminder)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Reminders")

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .frame(height: Self.headerHeight)
    }

    // MARK: - One due

    @ViewBuilder
    private func due(_ reminder: ReminderItem) -> some View {
        header(
            title: reminder.title,
            subtitle: [dueText(reminder), reminder.listTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        )
        HStack(spacing: 8) {
            chip("Snooze 1 Hour") { reminders.snooze() }
            chip("Complete", background: .reminder, foreground: .reminderOnAccent) { reminders.complete() }
        }
        .padding(.top, Self.chipsGap)
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

    // MARK: - Several due

    @ViewBuilder
    private func list(at now: Date) -> some View {
        let count = reminders.remaining.count
        header(
            title: count == 0 ? "All done" : "\(count) due today",
            subtitle: listNames(reminders.rows)
        )
        if !reminders.rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(reminders.rows.prefix(Self.maxRows)) { reminder in
                    row(reminder, at: now)
                }
            }
            .padding(.vertical, Self.listPadding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            .padding(.top, Self.listGap)
        }
    }

    /// A ring to tick it off, what it is and which list, and when it's
    /// due, or Overdue in red.
    private func row(_ reminder: ReminderItem, at now: Date) -> some View {
        let isTicked = reminders.ticked.contains(reminder.id)
        let isOverdue = RemindersMonitor.isOverdue(reminder, at: now)

        return HStack(spacing: 10) {
            Button {
                reminders.toggle(reminder)
            } label: {
                check(isTicked: isTicked, ring: isOverdue ? .reminderOverdue : Self.ringColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTicked ? "Completed: \(reminder.title)" : "Complete \(reminder.title)")

            VStack(alignment: .leading, spacing: 0) {
                Text(reminder.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isTicked ? Color.islandSecondary : .white)
                    .strikethrough(isTicked)
                Text(reminder.listTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(isOverdue ? "Overdue" : clockTime(reminder.due))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(isOverdue && !isTicked ? Color.reminderOverdue : Color.islandSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .contain)
    }

    /// An empty ring, or filled in orange once it's ticked off, as
    /// Reminders has it.
    private func check(isTicked: Bool, ring: Color) -> some View {
        ZStack {
            Circle()
                .strokeBorder(isTicked ? Color.reminder : ring, lineWidth: 1.5)
            if isTicked {
                Circle()
                    .fill(Color.reminder)
                    .padding(3.5)
            }
        }
        .frame(width: 18, height: 18)
        // Easier to hit than the ring alone.
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
}
