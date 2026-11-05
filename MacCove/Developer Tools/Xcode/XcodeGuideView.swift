//
//  XcodeGuideView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI

/// The setup guide opened up in the notch. First: how to get to
/// Behaviors in Xcode's Settings. Setting up: the group it's on,
/// its events and their scripts, each ticking off as Xcode runs it, with
/// the path and the rest of the steps a click away. As the first script
/// runs: why macOS is asking to let MacCove control Xcode. All set: a
/// check, then it leaves.
struct XcodeGuideView: View {
    let xcode: XcodeBuildMonitor
    let notchHeight: CGFloat

    @State private var copied = false

    private static let headerHeight: CGFloat = 56
    private static let listGap: CGFloat = 8
    private static let rowHeight: CGFloat = 40
    private static let listPadding: CGFloat = 4
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    static func bodyHeight(for xcode: XcodeBuildMonitor) -> CGFloat {
        var height: CGFloat = NotchViewModel.expandedTopGap + headerHeight
        height += chipsGap + chipHeight + bottomGap
        let rowCount = CGFloat(Self.rows(for: xcode).count)
        if rowCount > 0 {
            let list: CGFloat = listPadding * 2 + rowHeight * rowCount
            height += listGap + list
        }
        return height
    }

    var body: some View {
        let rows = Self.rows(for: xcode)

        VStack(spacing: 0) {
            header
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, Self.listPadding)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
                .padding(.top, Self.listGap)
            }
            chips
                .padding(.top, Self.chipsGap)
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            XcodeIcon(size: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .frame(height: Self.headerHeight)
    }

    private var title: String {
        if xcode.guide?.isAsking == true { return "Click OK to let MacCove control Xcode" }
        guard let group = xcode.guideGroup else { return "Xcode is connected" }
        if isAtStart { return "Connect Xcode · Open Behaviors" }
        return "Connect Xcode · \(group)"
    }

    /// The first step, until Next or the first script runs.
    private var isAtStart: Bool {
        xcode.guide?.isAtStart == true && xcode.guideGroup != nil
    }

    private var subtitle: String {
        let setup = xcode.setup
        if xcode.guide?.isAsking == true { return "For the scheme’s name, and Stop and Run" }
        if xcode.guideGroup == nil {
            return setup.isComplete ? "All \(setup.total) events added" : "\(setup.count) of \(setup.total) events added"
        }
        if isAtStart { return "Where MacCove’s scripts go in Xcode" }
        return "Select one, turn on Run, Choose Script…, ⇧⌘G, paste"
    }

    // MARK: Rows

    private struct Row: Identifiable {
        enum Status {
            /// In Xcode's settings.
            case added
            case next
            case notAdded
            /// One of the first step's instructions, numbered.
            case step(Int)
        }

        let id: String
        let text: String
        let detail: String
        let status: Status
    }

    /// While asking, the event that just ran; otherwise the group's events,
    /// with the first that hasn't run marked Next.
    private static func rows(for xcode: XcodeBuildMonitor) -> [Row] {
        guard let guide = xcode.guide else { return [] }
        if guide.isAsking {
            guard let event = guide.lastEvent,
                  let script = XcodeBehaviorScripts.scripts.first(where: { $0.event == event }) else { return [] }
            return [Row(id: script.event, text: "\(script.group) › \(script.behavior)", detail: "Xcode ran \(script.fileName)", status: .added)]
        }
        guard let group = xcode.guideGroup else { return [] }
        if guide.isAtStart {
            let first = XcodeBehaviorScripts.scripts.first
            return [
                Row(id: "settings", text: "Open Xcode’s Settings", detail: "Xcode › Settings…, or ⌘, in Xcode", status: .step(1)),
                Row(id: "behaviors", text: "Click Behaviors", detail: "Along the top of the Settings window", status: .step(2)),
                Row(
                    id: "first",
                    text: "Select \(first.map { "\($0.group) › \($0.behavior)" } ?? "Build › Starts")",
                    detail: "In the list on the left, then click Next",
                    status: .step(3)
                ),
            ]
        }
        let scripts = XcodeBehaviorScripts.scripts(in: group)
        let next = scripts.first { !xcode.setup.isSetUp($0) }
        return scripts.map { script in
            let status: Row.Status = if xcode.setup.isAdded(script) {
                .added
            } else if script.id == next?.id {
                .next
            } else {
                .notAdded
            }
            return Row(id: script.event, text: script.behavior, detail: script.fileName, status: status)
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Text(row.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            switch row.status {
            case .added:
                Label("Added", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.islandSucceeded)
            case .next:
                Text("Next")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.xcodeBuild)
            case .notAdded:
                Text("Not added")
                    .font(.system(size: 12))
                    .foregroundStyle(.islandSecondary)
            case let .step(number):
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.xcodeBuild))
                    .accessibilityLabel("Step \(number)")
            }
        }
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .combine)
    }

    // MARK: Buttons

    @ViewBuilder private var chips: some View {
        HStack(spacing: 8) {
            if xcode.guide?.isAsking == true {
                chip("Why It’s Needed") {
                    XcodeSetupWindow.show()
                }
            } else if isAtStart {
                chip("Open Xcode") {
                    XcodeCommand.open(workspacePath: nil)
                }
                chip("All Steps") {
                    XcodeSetupWindow.show()
                }
                chip("Next", background: .xcodeBuild, foreground: Color(red: 4 / 255, green: 23 / 255, blue: 46 / 255)) {
                    xcode.continueGuide()
                }
            } else if let group = xcode.guideGroup {
                chip(copied ? "Copied" : "Copy Path") {
                    XcodeBehaviorScripts.copyPath()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                chip("All Steps") {
                    XcodeSetupWindow.show()
                }
                chip("Skip \(group)") {
                    xcode.skip(group)
                }
            } else {
                chip("Settings") {
                    xcode.setup.showSettings()
                    xcode.endGuide()
                }
                chip("Done", background: .islandSucceeded, foreground: Color(red: 6 / 255, green: 33 / 255, blue: 15 / 255)) {
                    xcode.endGuide()
                }
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
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
