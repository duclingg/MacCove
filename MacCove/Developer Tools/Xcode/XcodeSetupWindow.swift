//
//  XcodeSetupWindow.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import SwiftUI

/// Connect Xcode: every step at once, opened from the guide in the notch
/// with All Steps or Why It's Needed. Xcode only runs scripts picked in its
/// own settings, so MacCove can't connect itself; this shows them all and
/// ticks each event off as it's added there. Setting up itself happens in
/// the notch.
enum XcodeSetupWindow {
    private static var window: NSWindow?
    private static var host: NSHostingController<XcodeSetupView>?

    static var isOpen: Bool {
        window?.isVisible == true
    }

    static func show() {
        if let existing = Self.window {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = XcodeSetupView(progress: .shared) {
            Self.window?.close()
        }
        let newHost = NSHostingController(rootView: view)
        newHost.sizingOptions = [.preferredContentSize]
        let newWindow = NSWindow(contentViewController: newHost)
        newWindow.title = "Connect Xcode"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        // Opened again later, it comes to the desktop you're on.
        newWindow.collectionBehavior.insert(.moveToActiveSpace)
        newWindow.center()
        Self.window = newWindow
        Self.host = newHost
        NSApp.activate()
        newWindow.makeKeyAndOrderFront(nil)
    }
}

/// The window's contents: the scripts, the Behaviors to point at them with
/// each event ticking off as it is added, and controlling Xcode.
struct XcodeSetupView: View {
    let progress: XcodeSetupProgress
    let close: () -> Void

    @State private var isShowingHelp = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                scriptsStep
                behaviorsStep
                controlStep
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()
            footer
                .padding(.horizontal, 22)
                .frame(height: 56)
        }
        .frame(width: 720)
        .task {
            await progress.refreshControl()
            // Xcode saves its Behaviors as they change: each ticks off
            // while you set it up.
            while !Task.isCancelled {
                progress.refreshBehaviors()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        // Xcode opened or quit: whether it can be asked about changes.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            Task { await progress.refreshControl() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            Task { await progress.refreshControl() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await progress.refreshControl() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                XcodeIcon(size: 40)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Show Xcode builds, tests and runs in the notch")
                    .font(.system(size: 15, weight: .semibold))
                Text("Xcode doesn’t let other apps change its settings, so you add MacCove’s scripts there yourself. About two minutes. Add only the ones you want.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                isShowingHelp = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Where it goes in Xcode")
            .accessibilityLabel("Where it goes in Xcode")
            .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
                XcodeSetupHelp()
            }
        }
    }

    // MARK: Steps

    private var scriptsStep: some View {
        StepCard {
            HStack(spacing: 12) {
                StepMarker(number: 1, isDone: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("The scripts are ready")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(XcodeBehaviorScripts.scriptCount) scripts in \(Text(ScriptsFolder.xcode.displayPath).font(.system(size: 11, design: .monospaced))). The folder’s path is on the clipboard.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Copy Path") {
                    XcodeBehaviorScripts.copyPath()
                }
                Button("Show in Finder") {
                    XcodeBehaviorScripts.showScripts()
                }
            }
            .controlSize(.small)
        }
    }

    private var behaviorsStep: some View {
        StepCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    StepMarker(number: 2, isDone: progress.isComplete)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add them in Xcode › Settings › Behaviors")
                            .font(.system(size: 13, weight: .semibold))
                        Text("For each event: select it, turn on Run, choose Choose Script… from the menu beside it, press ⇧⌘G, paste, and pick the script with the same name.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Open Xcode") {
                        XcodeCommand.open(workspacePath: nil)
                    }
                    .controlSize(.small)
                }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(XcodeBehaviorScripts.groups, id: \.self) { group in
                        groupColumn(group)
                    }
                }
            }
        }
    }

    private func groupColumn(_ group: String) -> some View {
        let scripts = XcodeBehaviorScripts.scripts(in: group)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(group)
                    .font(.system(size: 12, weight: .semibold))
                if group == XcodeBehaviorScripts.groups.first, progress.count == 0 {
                    Text("Start here")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
            .frame(height: 20)
            ForEach(Array(scripts.enumerated()), id: \.element.id) { index, script in
                if index > 0 {
                    Divider()
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(script.behavior)
                            .font(.system(size: 12))
                        Text(script.fileName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if progress.isAdded(script) {
                        Label("Added", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    } else {
                        Text("Not added")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 40)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var controlStep: some View {
        StepCard {
            HStack(spacing: 12) {
                StepMarker(number: 3, isDone: progress.control == .allowed)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let MacCove control Xcode")
                        .font(.system(size: 13, weight: .semibold))
                    Text(controlDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                controlStatus
                    .controlSize(.small)
            }
        }
    }

    private var controlDetail: String {
        if progress.control == .denied {
            return "Builds still show, without the scheme’s name or Stop and Run. Turn on MacCove › Xcode in Privacy & Security › Automation."
        }
        return "It’s for the scheme’s name, and for Stop, Run and Test Again in the notch."
    }

    @ViewBuilder private var controlStatus: some View {
        switch progress.control {
        case .allowed:
            Text("Allowed")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .asking:
            ProgressView()
        case .denied:
            Button("Open Privacy Settings") {
                AutomationPermission.openSettings()
            }
        case .notAsked, .asked, .waiting:
            if progress.isXcodeOpen {
                Button("Allow") {
                    Task { await progress.askToControl() }
                }
            } else {
                Text("Asks after your first build")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done", action: close)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var footerText: String {
        let count = progress.count
        let total = progress.total
        if count == 0 {
            return "Each event ticks off as you add it in Xcode."
        }
        if count == total {
            return "All \(total) added. You can close this window."
        }
        return "\(count) of \(total) added. The rest are optional; add them any time from Settings."
    }
}

// MARK: - Pieces

/// One of the window's numbered steps, on a rounded group.
private struct StepCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// The step's number, or a green check once it's done.
private struct StepMarker: View {
    let number: Int
    let isDone: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isDone ? Color.green : Color.accentColor)
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
            } else {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDone ? "Step \(number), done" : "Step \(number)")
    }
}

/// The window's ⓘ: the same five steps for each event, and what to do if
/// something's off.
private struct XcodeSetupHelp: View {
    private static let steps = [
        "Select an event under Build, Testing or Running.",
        "Turn on Run.",
        "Click the menu beside it and choose Choose Script….",
        "Press ⇧⌘G and paste. ~/Library is hidden in Open panels, so MacCove copied the path.",
        "Pick the script named for that event: Build › Starts is xcode-build-started.sh.",
    ]

    private static let answers = [
        ("I can’t find the folder in the Open panel", "~/Library is hidden there. Press ⇧⌘G and paste: Set Up put the path on the clipboard, and Copy Path puts it there again."),
        ("A build ran but nothing ticked", "Check that Run is on for that event and points at the script with the same name. Scripts do nothing while MacCove is closed, so open it first."),
        ("I clicked Don’t Allow", "Builds still show, without the scheme’s name or Stop and Run. Open Privacy Settings goes to Privacy & Security › Automation, where MacCove › Xcode turns it back on."),
        ("After updating MacCove", "Set Up rewrites the scripts under the same names, so Xcode’s Behaviors keep working and there’s nothing to redo."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where it goes in Xcode")
                .font(.system(size: 13, weight: .semibold))
            Text("In Xcode › Settings › Behaviors, the same five steps for each event:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))
                            .accessibilityHidden(true)
                        Text(step)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Text("If something’s off")
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.answers, id: \.0) { question, answer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question)
                            .font(.system(size: 12, weight: .semibold))
                        Text(answer)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
