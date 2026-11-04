//
//  RemindersPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func reminder(_ title: String, dueIn minutes: Double, list: String) -> ReminderItem {
    ReminderItem(id: title, title: title, due: .now.addingTimeInterval(minutes * 60), listTitle: list)
}

private let rent = reminder("Pay rent", dueIn: 0, list: "Home")
private let dentist = reminder("Call the dentist", dueIn: -3 * 60, list: "Personal")
private let dryCleaning = reminder("Pick up dry cleaning", dueIn: 90, list: "Personal")
private let today = [dentist, rent, dryCleaning]

private func compact(_ reminders: RemindersMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: RemindersCompactView.width(for: reminders, notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        RemindersCompactView(reminders: reminders, notchSize: notch)
    }
}

private func expanded(_ reminders: RemindersMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + RemindersExpandedView.bodyHeight(for: reminders)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        RemindersExpandedView(reminders: reminders, notchHeight: notch.height)
    }
}

#Preview("Due now") {
    compact(.preview(due: [rent], rows: [rent]))
}

#Preview("Due, expanded") {
    expanded(.preview(due: [rent], rows: [rent]))
}

#Preview("Several due today") {
    compact(.preview(due: [dentist, rent], rows: today))
}

#Preview("Several due today, expanded") {
    expanded(.preview(due: [dentist, rent], rows: today))
}

#Preview("One ticked off") {
    expanded(.preview(due: [rent], rows: today, ticked: [dentist.id]))
}

#Preview("Completed") {
    compact(.preview(due: [], completed: rent))
}

#Preview("Completed, expanded") {
    expanded(.preview(due: [], completed: rent))
}
#endif
