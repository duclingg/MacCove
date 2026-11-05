//
//  NotchGuideViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import SwiftUI

/// A guide's icon: a tool's, MacCove's, or a symbol on a tinted circle.
struct NotchGuideIcon: View {
    let icon: NotchGuide.Icon
    let size: CGFloat

    var body: some View {
        Group {
            switch icon {
            case let .tool(tool):
                ToolIcon(tool, size: size)
            case .app:
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            case let .symbol(name, color):
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: name)
                            .font(.system(size: size * 0.45, weight: .semibold))
                            .foregroundStyle(color)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The guide's icon in the left wing. In the right: how many steps are
/// done, or a red mark for an error.
struct NotchGuideCompactView: View {
    let guides: NotchGuides
    let notchSize: CGSize

    /// Each wing of a pill with "1 of 2" in it.
    private static let stepsWingWidth: CGFloat = 77

    static func width(for guides: NotchGuides, notch: CGSize) -> CGFloat {
        guard let guide = guides.current, !guide.steps.isEmpty else {
            return NotchViewModel.compactWidth(notch: notch)
        }
        return notch.width + stepsWingWidth * 2
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)

        HStack(spacing: 0) {
            if let guide = guides.current {
                NotchGuideIcon(icon: guide.icon, size: layout.artSize)
                Spacer(minLength: 0)
                trailing(guide, size: layout.artSize)
            }
        }
        .padding(.horizontal, layout.sideInset)
        .frame(width: Self.width(for: guides, notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(guides.current?.title ?? "MacCove")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func trailing(_ guide: NotchGuide, size: CGFloat) -> some View {
        if guide.tone == .error {
            Image(systemName: "exclamationmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.islandError)
                .frame(width: size, height: size)
        } else if !guide.steps.isEmpty {
            Text("\(guide.doneCount) of \(guide.steps.count)")
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        } else {
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
                .frame(width: size, height: size)
        }
    }
}

/// Beside another activity: just its icon.
struct NotchGuideMinimalView: View {
    let guides: NotchGuides
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)

        Group {
            if let guide = guides.current {
                NotchGuideIcon(icon: guide.icon, size: layout.artSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(guides.current?.title ?? "MacCove")
        .accessibilityAddTraits(.isButton)
    }
}

/// Opened up: the title, what's left to do, and its buttons.
struct NotchGuideExpandedView: View {
    let guides: NotchGuides
    let notchHeight: CGFloat

    static func bodyHeight(for guides: NotchGuides) -> CGFloat {
        guard let guide = guides.current else { return NotchViewModel.expandedTopGap + NotchGuideContent.bottomGap }
        let width = NotchViewModel.expandedWidth - NotchViewModel.expandedInset * 2
        return NotchViewModel.expandedTopGap + NotchGuideContent.height(of: guide, width: width)
    }

    var body: some View {
        Group {
            if let guide = guides.current {
                NotchGuideContent(guide: guide) { action in
                    guides.perform(action, in: guide)
                }
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }
}

/// A guide laid out on black: in the notch, and in the welcome card, which
/// stands in for the notch while it's up.
struct NotchGuideContent: View {
    let guide: NotchGuide
    let perform: (NotchGuide.Action) -> Void

    static let headerHeight: CGFloat = 56
    static let messageGap: CGFloat = 4
    static let messageLineLimit = 4
    static let listGap: CGFloat = 8
    static let rowHeight: CGFloat = 44
    static let listPadding: CGFloat = 4
    static let chipsGap: CGFloat = 12
    static let chipHeight: CGFloat = 36
    static let bottomGap: CGFloat = 14
    private static let messageFont = NSFont.systemFont(ofSize: 13)
    private static let messageLineHeight = NSLayoutManager().defaultLineHeight(for: messageFont)

    /// Worked out before anything is drawn, for the notch's size.
    static func height(of guide: NotchGuide, width: CGFloat) -> CGFloat {
        var height = headerHeight
        if let message = guide.message, !message.isEmpty {
            height += messageGap + messageLineHeight * CGFloat(messageLines(message, width: width))
        }
        if !guide.steps.isEmpty {
            height += listGap + listPadding * 2 + rowHeight * CGFloat(guide.steps.count)
        }
        if !guide.actions.isEmpty {
            height += chipsGap + chipHeight
        }
        return height + bottomGap
    }

    private static func messageLines(_ message: String, width: CGFloat) -> Int {
        let bounds = NSAttributedString(string: message, attributes: [.font: messageFont]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lines = Int((bounds.height / messageLineHeight).rounded(.up))
        return min(max(lines, 1), messageLineLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let message = guide.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
                    .lineLimit(Self.messageLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Self.messageGap)
            }
            if !guide.steps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(guide.steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(step, number: index + 1)
                    }
                }
                .padding(.vertical, Self.listPadding)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
                .padding(.top, Self.listGap)
            }
            if !guide.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(guide.actions) { action in
                        chip(action)
                    }
                }
                .padding(.top, Self.chipsGap)
            }
        }
        .padding(.bottom, Self.bottomGap)
    }

    private var header: some View {
        HStack(spacing: 12) {
            NotchGuideIcon(icon: guide.icon, size: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text(guide.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(guide.tone == .error ? Color.islandError : .white)
                if let subtitle = guide.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.islandSecondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .frame(height: Self.headerHeight)
    }

    private func stepRow(_ step: NotchGuide.Step, number: Int) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if step.isWatching, !step.isDone {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Circle()
                        .fill(step.isDone ? Color.islandSucceeded : .white.opacity(0.18))
                    if step.isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.black)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.text)
                    .font(.system(size: 13, weight: step.isDone ? .regular : .medium))
                    .foregroundStyle(step.isDone ? .islandSecondary : .white)
                if let detail = step.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.islandSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.isDone ? "Done: \(step.text)" : step.isWatching ? "In progress: \(step.text)" : "Step \(number): \(step.text)")
    }

    private func chip(_ action: NotchGuide.Action) -> some View {
        Button {
            perform(action)
        } label: {
            Text(action.title)
                .font(.system(size: 13, weight: action.isPrimary ? .semibold : .medium))
                .foregroundStyle(action.isPrimary ? Color.black : .white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(action.isPrimary ? Color.white : .white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
