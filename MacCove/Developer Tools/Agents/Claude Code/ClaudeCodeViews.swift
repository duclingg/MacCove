//
//  ClaudeCodeViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import SwiftUI

extension Color {
    static let claudeCode = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let agentWaiting = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    fileprivate static let onAccent = Color(red: 20 / 255, green: 20 / 255, blue: 19 / 255)
}

// MARK: ClaudeCodeIcon
struct ClaudeCodeIcon: View {
    let size: CGFloat

    /// Filled to its edges, as the notch's art, unlike `ToolIcon`, which
    /// pads it to sit beside other apps' icons.
    var body: some View {
        Image("ClaudeCode")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Progress through Claude's task list, or a spinning arc when the model
/// keeps none, as newer models don't.
private struct AgentRing: View {
    let progress: Double?
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat
    var trackOpacity = 0.2

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Circle()
                .stroke(.white.opacity(trackOpacity), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(progress, 0.02))
                    .stroke(color, style: style)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else {
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(color, style: style)
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
    }
}

private func agentClock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

/// The icon in the left wing. In the right: the ring while it works, an
/// orange dot while it waits for you, a green check when it's done.
struct ClaudeCodeCompactView: View {
    let claude: ClaudeCodeMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let session = claude.session

        HStack(spacing: 0) {
            ClaudeCodeIcon(size: layout.artSize)
            Spacer(minLength: 0)
            Group {
                switch session?.phase {
                case .working?, nil:
                    AgentRing(progress: session?.progress, color: .claudeCode, diameter: 20, lineWidth: 3)
                case .approval?, .question?, .plan?:
                    Circle()
                        .fill(Color.agentWaiting)
                        .frame(width: 9, height: 9)
                case .finished?:
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.islandSucceeded)
                }
            }
            .frame(width: layout.artSize, height: layout.artSize)
        }
        .padding(.horizontal, layout.sideInset)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.map { Self.accessibilityDescription($0) } ?? "Claude Code")
        .accessibilityAddTraits(.isButton)
    }

    private static func accessibilityDescription(_ session: ClaudeCodeMonitor.Session) -> String {
        switch session.phase {
        case .working: "Claude Code is working on \(session.task)"
        case let .approval(approval): "Claude Code is waiting for approval: \(approval.title)"
        case let .question(question): "Claude Code is asking: \(question.current.question)"
        case let .plan(plan): "Claude Code has a plan ready: \(plan.title)"
        case .finished: "Claude Code finished \(session.task)"
        }
    }
}

/// Claude Code in a bubble beside another activity: the icon, inside the
/// ring while it works and inside an orange one while it waits for you.
struct ClaudeCodeMinimalView: View {
    let claude: ClaudeCodeMonitor
    let notchSize: CGSize

    var body: some View {
        let session = claude.session
        let layout = BubbleLayout(notch: notchSize)
        Group {
            switch session?.phase {
            case .working?:
                ZStack {
                    AgentRing(
                        progress: session?.progress,
                        color: .claudeCode,
                        diameter: layout.ringDiameter,
                        lineWidth: layout.ringLineWidth,
                        trackOpacity: 0.18
                    )
                    ClaudeCodeIcon(size: Self.iconInRing(layout))
                }
            case .approval?, .question?, .plan?:
                ZStack {
                    Circle()
                        .stroke(Color.agentWaiting, lineWidth: layout.ringLineWidth)
                        .padding(layout.ringLineWidth / 2)
                        .frame(width: layout.ringDiameter, height: layout.ringDiameter)
                    ClaudeCodeIcon(size: Self.iconInRing(layout))
                }
            case .finished?, nil:
                ClaudeCodeIcon(size: layout.artSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Code")
        .accessibilityAddTraits(.isButton)
    }

    /// As big as fits inside the ring with a little space round it.
    private static func iconInRing(_ layout: BubbleLayout) -> CGFloat {
        (layout.ringDiameter - layout.ringLineWidth * 2 - 3).rounded()
    }
}

/// Opened up; the glyph opens the session, and hands anything waiting to
/// the terminal. Working: the prompt, what it's doing and the time so far,
/// with Stop.
/// Approval: what it wants to do, with Deny, Always Allow and Allow.
/// Question: the question and its options, one question at a time, and
/// Open in Claude Code to answer it there instead.
/// Plan: the plan's heading and opening lines, with Keep Planning, View
/// Plan and Approve.
/// Finished: how long it took, with Dismiss and Open Session.
struct ClaudeCodeExpandedView: View {
    let claude: ClaudeCodeMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let barGap: CGFloat = 10
    private static let barHeight: CGFloat = 6
    private static let footerGap: CGFloat = 6
    private static let footerHeight: CGFloat = 16
    private static let codeGap: CGFloat = 10
    private static let codePadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    private static let codeLineHeight: CGFloat = 18
    private static let codeLineLimit = 3
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let codeFontLineHeight = NSLayoutManager().defaultLineHeight(for: codeFont)
    private static let textGap: CGFloat = 10
    private static let textFont = NSFont.systemFont(ofSize: 13)
    private static let textLineHeight = NSLayoutManager().defaultLineHeight(for: textFont)
    private static let questionLineLimit = 3
    private static let summaryLineLimit = 4
    private static let optionsGap: CGFloat = 10
    private static let optionHeight: CGFloat = 40
    private static let optionSpacing: CGFloat = 6
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    static func bodyHeight(for session: ClaudeCodeMonitor.Session?) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        switch session?.phase {
        case .working?, nil:
            height += barGap + barHeight + footerGap + footerHeight
        case let .approval(approval)?:
            let lines = approval.detail.reduce(0) { $0 + wrappedLineCount($1) }
            if lines > 0 {
                height += codeGap + codePadding.top + codeLineHeight * CGFloat(lines) + codePadding.bottom
            }
            height += chipsGap + chipHeight
        case let .question(question)?:
            let item = question.current
            let options = CGFloat(item.options.count)
            height += textGap + textLineHeight * CGFloat(lineCount(item.question, font: textFont, width: contentWidth, limit: questionLineLimit))
            height += optionsGap + optionHeight * options + optionSpacing * (options - 1)
            height += chipsGap + chipHeight
        case let .plan(plan)?:
            if !plan.summary.isEmpty {
                let lines = lineCount(plan.summary, font: textFont, width: boxTextWidth, limit: summaryLineLimit)
                height += codeGap + codePadding.top + textLineHeight * CGFloat(lines) + codePadding.bottom
            }
            height += chipsGap + chipHeight
        case .finished?:
            height += chipsGap + chipHeight
        }
        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = claude.session {
                header(session)
                switch session.phase {
                case .working:
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        progress(session, at: context.date)
                    }
                case let .approval(approval):
                    if !approval.detail.isEmpty {
                        code(approval.detail)
                            .padding(.top, Self.codeGap)
                    }
                    HStack(spacing: 8) {
                        chip("Deny") { claude.deny() }
                        if approval.alwaysAllow != nil {
                            chip("Always Allow") { claude.alwaysAllow() }
                        }
                        chip("Allow", background: .claudeCode, foreground: .onAccent) { claude.allow() }
                    }
                    .padding(.top, Self.chipsGap)
                case let .question(question):
                    questionBody(question)
                case let .plan(plan):
                    if !plan.summary.isEmpty {
                        summary(plan.summary)
                            .padding(.top, Self.codeGap)
                    }
                    HStack(spacing: 8) {
                        chip("Keep Planning") { claude.keepPlanning() }
                        if plan.filePath != nil {
                            chip("View Plan") { claude.viewPlan() }
                        }
                        chip("Approve", background: .claudeCode, foreground: .onAccent) { claude.approvePlan() }
                    }
                    .padding(.top, Self.chipsGap)
                case .finished:
                    HStack(spacing: 8) {
                        chip("Dismiss") { claude.dismiss() }
                        chip("Open Session", background: .claudeCode, foreground: .onAccent) { claude.openSession() }
                    }
                    .padding(.top, Self.chipsGap)
                }
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private func header(_ session: ClaudeCodeMonitor.Session) -> some View {
        HStack(spacing: 12) {
            Button {
                claude.openSession()
            } label: {
                ClaudeCodeIcon(size: 44)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Session")

            VStack(alignment: .leading, spacing: 0) {
                Text(Self.title(session))
                    .font(.system(size: 15, weight: .semibold))
                Text(Self.subtitle(session))
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if session.phase == .working {
                Button {
                    claude.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.islandError)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.islandError.opacity(0.18)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func progress(_ session: ClaudeCodeMonitor.Session, at date: Date) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        if let fraction = session.progress {
                            Capsule()
                                .fill(Color.claudeCode)
                                .frame(width: proxy.size.width * fraction)
                                .animation(.easeOut(duration: 0.3), value: fraction)
                        } else {
                            // No task list: a short segment sweeps back and forth.
                            TimelineView(.animation) { context in
                                let segment = proxy.size.width * 0.3
                                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                                let sweep = (1 - cos(phase * 2 * .pi)) / 2
                                Capsule()
                                    .fill(Color.claudeCode)
                                    .frame(width: segment)
                                    .offset(x: (proxy.size.width - segment) * sweep)
                            }
                        }
                    }
                }
                .frame(height: Self.barHeight)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            HStack {
                Text(session.taskCount > 0
                     ? "\(session.tasksDone) of \(session.taskCount) tasks"
                     : "\(session.toolUses) step\(session.toolUses == 1 ? "" : "s")")
                Spacer()
                Text(agentClock(date.timeIntervalSince(session.startedAt)))
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.islandSecondary)
            .lineLimit(1)
            .frame(height: Self.footerHeight)
            .padding(.top, Self.footerGap)
        }
        .padding(.top, Self.barGap)
    }

    private func code(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .lineLimit(Self.codeLineLimit)
                    .lineSpacing(Self.codeLineHeight - Self.codeFontLineHeight)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.codeLineHeight * CGFloat(Self.wrappedLineCount(line)))
            }
        }
        // The same SF Mono that `codeFont` measures.
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.86))
        .padding(Self.codePadding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    private func questionBody(_ question: ClaudeCodeMonitor.Question) -> some View {
        let item = question.current
        let lines = Self.lineCount(item.question, font: Self.textFont, width: Self.contentWidth, limit: Self.questionLineLimit)
        return VStack(spacing: 0) {
            Text(item.question)
                .font(.system(size: 13))
                .lineLimit(Self.questionLineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.textLineHeight * CGFloat(lines), alignment: .top)
                .padding(.top, Self.textGap)

            VStack(spacing: Self.optionSpacing) {
                ForEach(item.options, id: \.label) { option in
                    optionRow(option, isMultiSelect: item.multiSelect, isSelected: question.selected.contains(option.label))
                }
            }
            .padding(.top, Self.optionsGap)

            HStack(spacing: 8) {
                // Claude Code asks it there instead, where an answer of your
                // own can be typed.
                chip("Open in Claude Code") { claude.openSession() }
                if item.multiSelect {
                    chip(
                        "Submit",
                        background: question.selected.isEmpty ? .white.opacity(0.12) : .claudeCode,
                        foreground: question.selected.isEmpty ? .islandSecondary : .onAccent
                    ) { claude.submitChoices() }
                    .disabled(question.selected.isEmpty)
                }
            }
            .padding(.top, Self.chipsGap)
        }
        // A new question replaces the last rather than reshuffling it.
        .id(question.index)
        .transition(.opacity)
    }

    /// The label, and what choosing it means. A multiple choice ticks it.
    private func optionRow(_ option: ClaudeCodeMonitor.Question.Option, isMultiSelect: Bool, isSelected: Bool) -> some View {
        Button {
            claude.choose(option.label)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.islandSecondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if isMultiSelect {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.claudeCode : .white.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Self.optionHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.claudeCode.opacity(0.2) : .white.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func summary(_ text: String) -> some View {
        let lines = Self.lineCount(text, font: Self.textFont, width: Self.boxTextWidth, limit: Self.summaryLineLimit)
        return Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.islandSecondary)
            .lineLimit(Self.summaryLineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.textLineHeight * CGFloat(lines), alignment: .top)
            .padding(Self.codePadding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
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

    private static let contentWidth = NotchViewModel.expandedWidth - NotchViewModel.expandedInset * 2
    /// Inside the rounded box a command or plan sits in.
    private static let boxTextWidth = contentWidth - codePadding.leading - codePadding.trailing

    private static func wrappedLineCount(_ text: String) -> Int {
        lineCount(text, font: codeFont, width: boxTextWidth, limit: codeLineLimit)
    }

    /// The island's height is worked out before anything is drawn, so text
    /// is measured the way it will wrap.
    private static func lineCount(_ text: String, font: NSFont, width: CGFloat, limit: Int) -> Int {
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return min(max(Int((bounds.height / lineHeight).rounded()), 1), limit)
    }

    private static func title(_ session: ClaudeCodeMonitor.Session) -> String {
        switch session.phase {
        case let .approval(approval): approval.title
        case let .question(question): question.current.header.isEmpty ? "Claude has a question" : question.current.header
        case let .plan(plan): plan.title
        case .working, .finished: session.task
        }
    }

    /// "MacCove · Editing IslandView.swift", "Claude Code · MacCove",
    /// "Claude Code · MacCove · 1 of 3", "Plan · MacCove", or "Done in 6:48
    /// · 5 files changed".
    private static func subtitle(_ session: ClaudeCodeMonitor.Session) -> String {
        switch session.phase {
        case .working:
            return [session.project, session.activity ?? "Thinking"].filter { !$0.isEmpty }.joined(separator: " · ")
        case .approval:
            return ["Claude Code", session.project].filter { !$0.isEmpty }.joined(separator: " · ")
        case let .question(question):
            let progress = question.items.count > 1 ? "\(question.index + 1) of \(question.items.count)" : ""
            return ["Claude Code", session.project, progress].filter { !$0.isEmpty }.joined(separator: " · ")
        case .plan:
            return ["Plan", session.project].filter { !$0.isEmpty }.joined(separator: " · ")
        case .finished:
            let took = session.finishedAt.map { "Done in " + agentClock($0.timeIntervalSince(session.startedAt)) } ?? "Done"
            let files = session.editedFiles.count
            return files > 0 ? "\(took) · \(files) file\(files == 1 ? "" : "s") changed" : took
        }
    }
}
