//
//  XcodeGuideView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI

/// The setup guide opened up in the notch. Setting up: the group it's on,
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
        return "Connect Xcode · \(group)"
    }

    private var subtitle: String {
        let setup = xcode.setup
        if xcode.guide?.isAsking == true { return "For the scheme’s name, and Stop and Run" }
        if xcode.guideGroup == nil {
            return setup.isComplete ? "All \(setup.total) events working" : "\(setup.count) of \(setup.total) events working"
        }
        return "Run › Choose Script…, then ⇧⌘G and paste"
    }

    // MARK: Rows

    private struct Row: Identifiable {
        enum Status {
            case working
            case next
            case notRun
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
            return [Row(id: script.event, text: "\(script.group) › \(script.behavior)", detail: "Xcode ran \(script.fileName)", status: .working)]
        }
        guard let group = xcode.guideGroup else { return [] }
        let scripts = XcodeBehaviorScripts.scripts(in: group)
        let next = scripts.first { !xcode.setup.isWorking($0) }
        return scripts.map { script in
            let status: Row.Status = xcode.setup.isWorking(script) ? .working : script.id == next?.id ? .next : .notRun
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
            case .working:
                Label("Working", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.islandSucceeded)
            case .next:
                Text("Next")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.xcodeBuild)
            case .notRun:
                Text("Not run yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.islandSecondary)
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
                    XcodeSetupWindow.show(canGuideInNotch: true)
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
                    XcodeSetupWindow.show(canGuideInNotch: true)
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
