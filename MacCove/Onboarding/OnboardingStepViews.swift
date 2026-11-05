//
//  OnboardingStepViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import ServiceManagement
import SwiftUI

/// What's in the card above its footer, for the step it's on.
struct OnboardingStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        Group {
            switch model.step {
            case .move: MoveStep()
            case .cleanup: CleanupStep(location: model.installLocation)
            case .welcome: WelcomeStep(hasNotch: model.hasNotch)
            case .how: HowStep()
            case .access: AccessStep(model: model)
            case .connect: ConnectStep(model: model)
            case let .preview(tool): PreviewStep(tool: tool)
            case .displays: DisplaysStep()
            case .updates: UpdatesStep()
            case .done: DoneStep(hasNotch: model.hasNotch, hasMenuBarItem: model.menuBarItem.isShown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared pieces

private struct StepTitle: View {
    let text: String
    var size: CGFloat = 20

    init(_ text: String, size: CGFloat = 20) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .tracking(-0.3)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct StepNote: View {
    let text: String
    var size: CGFloat = 13

    init(_ text: String, size: CGFloat = 13) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(OnboardingStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Allowed" with a tick, "Waiting for approval", and the like.
private struct StatusLabel: View {
    let text: String
    let color: Color
    var showsCheck = false
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 5) {
            if showsCheck {
                Image(systemName: "checkmark")
                    .font(.system(size: size - 2, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// A symbol on a coloured tile, as the design draws each row's icon.
private struct SymbolTile: View {
    let symbol: String
    let color: Color
    var glyph: Color = .white
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(glyph)
            }
            .accessibilityHidden(true)
    }
}

/// The sky the illustrations hang their notches from.
private let illustrationSky = LinearGradient(
    colors: [Color(red: 27 / 255, green: 38 / 255, blue: 56 / 255), Color(red: 59 / 255, green: 70 / 255, blue: 96 / 255)],
    startPoint: .top,
    endPoint: .bottom
)

private let artworkOrange = Color(red: 246 / 255, green: 178 / 255, blue: 107 / 255)
private let agentOrange = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

/// A black shape hanging from the top edge, rounded at the bottom.
private func hanging(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
    UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        .fill(.black)
        .frame(width: width, height: height)
}

// MARK: - Before the welcome

private struct MoveStep: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                StepTitle("Copy MacCove to Applications?", size: 18)
                StepNote("It’s running from the disk image, so it would be gone after you eject it. From Applications it can also open at login and install the Low Power Mode helper.")
            }
        }
    }
}

private struct CleanupStep: View {
    let location: InstallLocation

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                StepTitle("Clean up the installer?", size: 18)
                StepNote(detail)
            }
        }
    }

    private var image: URL? {
        if case let .leftoverImage(_, image) = location { image } else { nil }
    }

    private var icon: NSImage {
        if case let .leftoverImage(volume, image) = location {
            return NSWorkspace.shared.icon(forFile: (image ?? volume).path(percentEncoded: false))
        }
        return NSApp.applicationIconImage
    }

    private var detail: String {
        let installed = InstallLocation.isInApplications ? "MacCove is in Applications now." : "MacCove is installed now."
        guard let image else {
            return "\(installed) Eject the MacCove disk image."
        }
        let folder = FileManager.default.displayName(atPath: image.deletingLastPathComponent().path(percentEncoded: false))
        return "\(installed) Eject the MacCove disk image and move \(image.lastPathComponent) from \(folder) to the Trash."
    }
}

// MARK: - 1 · Welcome

private struct WelcomeStep: View {
    let hasNotch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            illustration
            Text("Welcome to MacCove")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.4)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            StepNote(
                hasNotch
                    ? "Live activities around the notch: music, battery, meetings and downloads, plus the tools you build with."
                    : "Live activities at the top of the screen: music, battery, meetings and downloads, plus the tools you build with.",
                size: 14
            )
            .padding(.top, 6)
            Text("Free and open source under GPL-3.0.")
                .font(.system(size: 12))
                .foregroundStyle(OnboardingStyle.tertiary)
                .padding(.top, 10)
        }
    }

    /// The notch playing music, with an agent working on the left and a
    /// ring filling on the right, over a window.
    private var illustration: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(illustrationSky)
            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(height: 60)
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity, alignment: .bottom)
            HStack(spacing: 12) {
                hanging(width: 32, height: 30, radius: 10)
                    .overlay {
                        Image(systemName: "asterisk")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(agentOrange)
                    }
                hanging(width: 236, height: 30, radius: 14)
                    .overlay {
                        HStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(LinearGradient(colors: [artworkOrange, Color(red: 28 / 255, green: 37 / 255, blue: 65 / 255)], startPoint: .topTrailing, endPoint: .bottomLeading))
                                .frame(width: 18, height: 18)
                            Spacer()
                            HStack(alignment: .center, spacing: 2) {
                                ForEach([6.0, 12, 9, 5], id: \.self) { height in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(artworkOrange)
                                        .frame(width: 2.5, height: height)
                                }
                            }
                        }
                        .padding(.horizontal, 11)
                    }
                hanging(width: 32, height: 30, radius: 10)
                    .overlay {
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(.orange, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 14, height: 14)
                    }
            }
        }
        .frame(height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - 2 · How it works

private struct HowStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle("How it works")
            HStack(alignment: .top, spacing: 12) {
                column("Hover to peek", "The notch grows a little to show it’s listening.") {
                    hanging(width: 132, height: 26, radius: 12)
                        .overlay(alignment: .top) {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .shadow(color: .black, radius: 0.5)
                                .offset(x: 12, y: 14)
                        }
                }
                column("Click to open", "Controls, details and buttons, without switching apps.") {
                    hanging(width: 150, height: 78, radius: 20)
                        .overlay(alignment: .top) {
                            VStack(spacing: 0) {
                                HStack(spacing: 7) {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(LinearGradient(colors: [artworkOrange, Color(red: 28 / 255, green: 37 / 255, blue: 65 / 255)], startPoint: .topTrailing, endPoint: .bottomLeading))
                                        .frame(width: 22, height: 22)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Capsule().fill(.white.opacity(0.8)).frame(width: 64, height: 5)
                                        Capsule().fill(.white.opacity(0.35)).frame(width: 40, height: 4)
                                    }
                                    Spacer(minLength: 0)
                                }
                                Spacer(minLength: 0)
                                Capsule()
                                    .fill(.white.opacity(0.2))
                                    .frame(height: 3)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(.white).frame(width: 52, height: 3)
                                    }
                            }
                            .padding(.top, 22)
                            .padding(.bottom, 12)
                            .padding(.horizontal, 10)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
                }
                column("Up to three at once", "The most important one in the middle, two more hang beside it.") {
                    HStack(spacing: 8) {
                        hanging(width: 20, height: 20, radius: 7)
                            .overlay {
                                Circle().fill(agentOrange).frame(width: 8, height: 8)
                            }
                        hanging(width: 96, height: 20, radius: 9)
                        hanging(width: 20, height: 20, radius: 7)
                            .overlay {
                                Circle().stroke(.orange, lineWidth: 2).frame(width: 8, height: 8)
                            }
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    private func column<Picture: View>(_ title: String, _ text: String, @ViewBuilder picture: () -> Picture) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(illustrationSky)
                picture()
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 10)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(OnboardingStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 3 · Permissions

private struct AccessStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle("Allow a few things")
            StepNote("All optional. macOS asks only when you click Allow, and you can change these later.")
                .padding(.top, 4)
            VStack(spacing: 0) {
                row("Control Music", detail: "Favorite songs in Music, and show exactly where a song is up to.", symbol: "music.note", color: .pink) {
                    trailing(model.music, allow: "Allow", action: model.allowMusic, openSettings: MusicAutomation.openSettings)
                }
                row("Control Terminal", detail: "Brings forward the window a command or coding agent ran in.", symbol: "terminal", color: .gray) {
                    trailing(model.terminalControl, allow: "Allow", action: model.allowTerminal, openSettings: AutomationPermission.openSettings)
                }
                if model.hasITerm {
                    row("Control iTerm", detail: "Brings forward its window, and presses Esc to stop an agent.", symbol: "apple.terminal", color: .green) {
                        trailing(model.iTermControl, allow: "Allow", action: model.allowITerm, openSettings: AutomationPermission.openSettings)
                    }
                }
                row(
                    "Keep clear of app menus",
                    detail: model.accessibility == .waiting
                        ? "Turn on MacCove in System Settings › Privacy & Security › Accessibility."
                        : "Activities beside the notch move out of the way of the menus of the app in front.",
                    symbol: "accessibility",
                    color: .indigo
                ) {
                    trailing(model.accessibility, allow: "Allow", action: model.allowAccessibility) {
                        AppMenuExtent.openSettings()
                    }
                }
                row(
                    "Find AirPlay speakers",
                    // macOS asks about Local Network once, ever: a reset
                    // doesn't bring the question back, so say where it is.
                    detail: networkDetail,
                    symbol: "airplayaudio",
                    color: .blue
                ) {
                    if model.network.access == .asked || model.network.access == .denied {
                        Button("Turn On") {
                            model.allowNetwork()
                        }
                            .buttonStyle(OnboardingButtonStyle(kind: .row))
                    } else {
                        trailing(model.network.access, allow: "Allow", action: model.allowNetwork) {
                            LocalNetworkProbe.shared.turnOn()
                        }
                    }
                }
                if model.hasHelper {
                    row(
                        "Low Power Mode helper",
                        detail: model.helper == .waiting
                            ? "Turn it on under MacCove in System Settings › General › Login Items."
                            : "Turn Low Power Mode on from the notch with no password. You approve it once in Login Items.",
                        symbol: "bolt.fill",
                        color: .yellow,
                        glyph: Color(red: 28 / 255, green: 19 / 255, blue: 0)
                    ) {
                        trailing(model.helper, allow: "Install", action: model.installHelper) {
                            SystemSettings.openLoginItems()
                        }
                    }
                }
                row("Open at login", detail: "Starts MacCove whenever you log in.", symbol: "power", color: .gray) {
                    Toggle("Open at login", isOn: Binding(
                        get: { model.launchAtLogin.isEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                }
            }
            .padding(.top, 12)
        }
    }

    private var networkDetail: String {
        switch model.network.access {
        case .denied: "Off for MacCove. Turn it on under Local Network in Privacy & Security."
        case .asked: "macOS didn’t answer. Check MacCove under Local Network in Privacy & Security."
        default: "Shows the right icon for HomePods and TVs on your network."
        }
    }

    private func row<Trailing: View>(
        _ title: String,
        detail: String,
        symbol: String,
        color: Color,
        glyph: Color = .white,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, color: color, glyph: glyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OnboardingStyle.separator)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func trailing(
        _ access: OnboardingAccess,
        allow: String,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        switch access {
        case .notAsked:
            Button(allow, action: action)
                .buttonStyle(OnboardingButtonStyle(kind: .row))
        case .asking:
            ProgressView()
                .controlSize(.small)
        case .asked:
            StatusLabel(text: "Asked", color: OnboardingStyle.secondary)
        case .allowed:
            StatusLabel(text: "Allowed", color: .green, showsCheck: true)
        case .waiting:
            StatusLabel(text: "Waiting for approval", color: .orange)
        case .denied:
            Button("Open Settings") {
                model.openSystemSettings(openSettings)
            }
                .buttonStyle(OnboardingButtonStyle(kind: .row))
        }
    }
}

// MARK: - 4 · What shows up

private struct ConnectStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle("Choose what shows up")
            Picker("Kinds of activities", selection: $model.tab) {
                ForEach(OnboardingModel.Tab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 10)
            StepNote(hint, size: 12)
                .padding(.top, 8)
            let tiles = model.tab == .everyday ? everydayTiles : developerTiles
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 8) {
                        TileView(tile: tiles[start])
                        if start + 1 < tiles.count {
                            TileView(tile: tiles[start + 1])
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private var hint: String {
        switch model.tab {
        case .everyday:
            "Each asks macOS for what it needs when you turn it on. Nothing asks later by itself."
        case .developerTools:
            "All off to start. Set Up shows what MacCove will change, then asks macOS for what the tool needs."
        }
    }

    // MARK: Everyday

    private var everydayTiles: [Tile] {
        var tiles = [
            Tile(
                id: "calendar", name: "Next meeting", detail: "Join calls from the notch",
                icon: .symbol("calendar", .blue),
                trailing: eventKit(isEnabled: model.calendar.isEnabled, access: model.calendar.access, enable: model.allowCalendar, openSettings: CalendarMonitor.openAccessSettings)
            ),
            Tile(
                id: "reminders", name: "Reminders", detail: "Ones with a due time, as they come due",
                icon: .symbol("checklist", .orange),
                trailing: eventKit(isEnabled: model.reminders.isEnabled, access: model.reminders.access, enable: model.allowReminders, openSettings: RemindersMonitor.openAccessSettings)
            ),
            Tile(
                id: "shelf", name: "File shelf", detail: "Drop files on the notch to keep them",
                icon: .symbol("tray", .white),
                trailing: .toggle(model.shelf.isEnabled, { model.shelf.setEnabled($0) })
            ),
            Tile(
                id: "clipboard", name: "Clipboard history", detail: "Last few copies, kept 24 hours",
                icon: .symbol("doc.on.clipboard", .white),
                trailing: .toggle(model.isClipboardEnabled, { model.setClipboardEnabled($0) })
            ),
            Tile(
                id: "batteries", name: "Device batteries", detail: "Mice, keyboards and controllers",
                icon: .symbol("computermouse", .green),
                trailing: .toggle(model.deviceBatteries.isEnabled, { model.deviceBatteries.setEnabled($0) })
            ),
            Tile(
                id: "downloads", name: "Downloads", detail: "Progress of files downloading",
                icon: .symbol("arrow.down.circle", .blue),
                trailing: .toggle(model.downloads.isEnabled, { model.downloads.setEnabled($0) })
            ),
            Tile(
                id: "mirror", name: "Mirror", detail: "Check your camera before a call",
                icon: .symbol("video", .green),
                trailing: cameraTrailing
            ),
        ]
        // Once Next meeting's on, what it can do with more access.
        if model.calendar.isEnabled, model.calendar.access == .granted {
            tiles.insert(contentsOf: [
                Tile(
                    id: "leave", name: "When to leave", detail: "Travel time to events with a place",
                    icon: .symbol("car", .blue),
                    trailing: leaveTimeTrailing
                ),
                Tile(
                    id: "birthdays", name: "Birthday messages", detail: "Message people on their birthday",
                    icon: .symbol("gift", .pink),
                    trailing: contactsTrailing
                ),
            ], at: 1)
        }
        return tiles
    }

    private var cameraTrailing: Tile.Trailing {
        switch model.mirror.access {
        case .granted: .on
        case .denied: .button("Open Settings", { model.openSystemSettings(MirrorCamera.openAccessSettings) })
        case .notDetermined: .button("Allow", model.allowCamera)
        }
    }

    private var leaveTimeTrailing: Tile.Trailing {
        switch (model.calendar.isLeaveTimeEnabled, model.calendar.locationAccess) {
        case (true, .granted): .on
        case (_, .denied): .button("Open Settings", {
            model.calendar.setLeaveTimeEnabled(true)
            model.openSystemSettings(CalendarMonitor.openLocationSettings)
        })
        case (true, .notDetermined): .progress
        default: .button("Allow", model.allowLeaveTime)
        }
    }

    private var contactsTrailing: Tile.Trailing {
        switch model.contacts {
        case .allowed: .on
        case .denied: .button("Open Settings", {
            model.openSystemSettings { SystemSettings.openPrivacy("Privacy_Contacts") }
        })
        default: .button("Allow", model.allowContacts)
        }
    }

    /// Calendar and Reminders: Allow turns it on, which asks macOS.
    private func eventKit(
        isEnabled: Bool,
        access: CalendarMonitor.Access,
        enable: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> Tile.Trailing {
        switch (isEnabled, access) {
        case (true, .granted):
            .on
        case (_, .denied):
            .button("Open Settings", {
                enable()
                model.openSystemSettings(openSettings)
            })
        case (true, .notDetermined):
            .progress
        default:
            .button("Allow", enable)
        }
    }

    // MARK: Developer tools

    /// Installed tools first, all off until Set Up; agents that aren't
    /// installed are dimmed at the end.
    private var developerTiles: [Tile] {
        var tiles: [Tile] = model.installedAgents.map { tool in
            let hasHooks = model.agentsWithHooks.contains(tool)
            return Tile(
                id: tool.rawValue, name: tool.name,
                detail: hasHooks ? "Hooks in \(tool.path)" : "Adds hooks to \(tool.path)",
                icon: .tool(Self.icon(tool)),
                trailing: hasHooks ? .on : .button("Set Up", { model.showPreview(tool) })
            )
        }
        if model.isXcodeInstalled {
            tiles.append(Tile(
                id: "xcode", name: "Xcode", detail: "Scripts for Xcode’s Behaviors",
                icon: .tool(ToolIcon(.xcode, size: 30)),
                trailing: model.hasXcodeScripts
                    ? .on
                    : model.isXcodeGuiding ? .status("Setting up", Color.xcodeBuild) : .button("Set Up", model.setUpXcode)
            ))
        }
        tiles.append(Tile(
            id: "terminal", name: "Terminal",
            detail: model.hasTerminalHook ? "Hook in ~/.zshrc" : "Adds two lines to ~/.zshrc",
            icon: .tool(ToolIcon(.terminal, size: 30)),
            trailing: model.hasTerminalHook ? .on : .button("Set Up", model.setUpTerminal)
        ))
        tiles.append(Tile(
            id: "github", name: "GitHub", detail: "Uses your gh sign-in, or a token",
            icon: .tool(ToolIcon(.gitHub, size: 30)),
            trailing: model.isGitHubConnected ? .on : model.isWaitingForGitHub ? .progress : .button("Connect", model.connectGitHub)
        ))
        for tool in AITool.allCases where !model.installedAgents.contains(tool) {
            tiles.append(Tile(
                id: tool.rawValue, name: tool.name, detail: "Not installed",
                icon: .tool(Self.icon(tool)), trailing: .status("Not found", OnboardingStyle.secondary), isDimmed: true
            ))
        }
        return tiles
    }

    /// The agent's icon at the tile's size.
    private static func icon(_ tool: AITool) -> ToolIcon {
        switch tool {
        case .claude: ToolIcon(.claudeCode, size: 30)
        case .codex: ToolIcon(.codex, size: 30)
        case .cursor: ToolIcon(.cursor, size: 30)
        }
    }
}

/// One of What Shows Up's tiles.
private struct Tile: Identifiable {
    enum Icon {
        case symbol(String, Color)
        case tool(ToolIcon)
    }

    enum Trailing {
        case button(String, () -> Void)
        case status(String, Color)
        /// Set up or allowed.
        case on
        case toggle(Bool, (Bool) -> Void)
        /// Waiting for macOS to ask.
        case progress
    }

    let id: String
    let name: String
    let detail: String
    let icon: Icon
    let trailing: Trailing
    var isDimmed = false
}

private struct TileView: View {
    let tile: Tile

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(tile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(tile.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tile.detail)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(OnboardingStyle.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(tile.isDimmed ? 0.45 : 1)
    }

    @ViewBuilder private var icon: some View {
        switch tile.icon {
        case let .symbol(symbol, color):
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.1))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                }
        case let .tool(icon):
            icon
        }
    }

    @ViewBuilder private var trailing: some View {
        switch tile.trailing {
        case let .button(title, action):
            Button(title, action: action)
                .buttonStyle(OnboardingButtonStyle(kind: .tile))
        case let .status(text, color):
            StatusLabel(text: text, color: color, size: 12)
        case .on:
            StatusLabel(text: "On", color: .green, showsCheck: true, size: 12)
        case let .toggle(isOn, set):
            Toggle(tile.name, isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
        case .progress:
            ProgressView()
                .controlSize(.small)
        }
    }
}

// MARK: - 4a · Set Up preview

private struct PreviewStep: View {
    let tool: AITool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle("Set up \(tool.name)")
            Text("MacCove will add these hooks to \(Text(tool.path).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.86))). Nothing else changes, and Remove takes them out again.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                line("  \"hooks\": {", color: OnboardingStyle.tertiary)
                ForEach(tool.setup.hookEvents, id: \.self) { event in
                    line("+   \(event.padding(toLength: 20, withPad: " ", startingAt: 0))agent-hook.sh", color: .green)
                }
                line("  }", color: OnboardingStyle.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            Text("A backup is saved as \(backupName).")
                .font(.system(size: 12))
                .foregroundStyle(OnboardingStyle.tertiary)
                .padding(.top, 10)
        }
    }

    private var backupName: String {
        (tool.path as NSString).lastPathComponent + ".maccove-backup"
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(OnboardingStyle.mono)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(height: 20)
    }
}

// MARK: - 5 · Displays

private struct DisplaysStep: View {
    @AppStorage(NotchSettings.noNotchVisibilityKey) private var visibility = NotchSettings.defaultNoNotchVisibility

    private struct Display: Identifiable {
        let id: Int
        let name: String
        let hasNotch: Bool
        let isBuiltIn: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle("Your displays")
            VStack(spacing: 0) {
                ForEach(displays) { display in
                    HStack(spacing: 12) {
                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                            .font(.system(size: 17))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(display.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 8)
                        Text(display.hasNotch ? "Notch" : "No notch")
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingStyle.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                }
            }
            .background(OnboardingStyle.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 12)
            Text("On displays without a notch, show MacCove")
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 16)
            Picker("On displays without a notch, show MacCove", selection: $visibility) {
                ForEach(NotchSettings.NoNotchVisibility.allCases, id: \.self) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 8)
            StepNote(hint, size: 12)
                .padding(.top, 8)
        }
    }

    private var displays: [Display] {
        NSScreen.screens.enumerated().map { index, screen in
            Display(id: Int(screen.displayID ?? UInt32(index)), name: screen.localizedName, hasNotch: screen.hasNotch, isBuiltIn: screen.isBuiltIn)
        }
    }

    private var hint: String {
        switch visibility {
        case .duringActivities: "Slides down from the top edge when something starts, and hides when nothing is running."
        case .always: "Keeps a black pill at the top centre, like the built-in display."
        case .never: "Activities only show on displays with a notch."
        }
    }
}

// MARK: - 6 · Updates and privacy

private struct UpdatesStep: View {
    @AppStorage(UpdateChecker.automaticKey) private var checksAutomatically = true
    @AppStorage(UpdateChecker.betaKey) private var includesBetas = false

    private static let repositoryURL = URL(string: "https://github.com/\(UpdateChecker.repository)")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle("Updates and privacy")
            VStack(spacing: 0) {
                // brew upgrade handles a Homebrew install's updates.
                if UpdateChecker.isInstalledWithHomebrew {
                    row("Updated with Homebrew", detail: "brew upgrade keeps MacCove up to date, so it doesn’t check by itself.") {
                        EmptyView()
                    }
                } else {
                    row("Check for updates automatically", detail: "Looks for new releases on GitHub once a day and asks before downloading.") {
                        toggle("Check for updates automatically", isOn: $checksAutomatically)
                    }
                    row("Include beta releases", detail: "Get new activities early. They may be rough.") {
                        toggle("Include beta releases", isOn: $includesBetas)
                    }
                }
            }
            .padding(.top, 12)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Nothing about you leaves this Mac. No analytics and no account. MacCove only goes online to check for updates and for integrations you turn on, like GitHub.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 6)
            HStack(spacing: 16) {
                Link("Source code on GitHub", destination: Self.repositoryURL)
                Link("Report a bug", destination: Self.repositoryURL.appending(path: "issues"))
            }
            .font(.system(size: 12, weight: .medium))
            .tint(OnboardingStyle.link)
            .padding(.top, 12)
        }
    }

    private func row<Trailing: View>(_ title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OnboardingStyle.separator)
                .frame(height: 0.5)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.green)
    }
}

// MARK: - Done

private struct DoneStep: View {
    let hasNotch: Bool
    let hasMenuBarItem: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    .accessibilityHidden(true)
                StepTitle("You’re all set")
            }
            StepNote(text)
                .padding(.top, 12)
        }
    }

    private var text: String {
        let tryIt = hasNotch ? "Hover the notch to try it." : "Activities drop from the top of the screen as they start."
        let later = hasMenuBarItem
            ? "Anything here can be changed later in Settings, in the menu bar under the capsule."
            : "Anything here can be changed later in Settings: open MacCove again to get there."
        return "\(tryIt) \(later)"
    }
}
