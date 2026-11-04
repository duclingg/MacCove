//
//  AppDelegate.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var viewModel: NotchViewModel?
    private var xcode: XcodeBuildMonitor?
    private var terminal: TerminalCommandMonitor?
    private var agentBridge: AgentBridge?
    private let music = MusicScripting()
    // Made here rather than at launch, so Settings has them too.
    private(set) lazy var nowPlaying = NowPlayingModel(music: music)
    private(set) lazy var battery = BatteryMonitor()
    private(set) lazy var signIn = SignInMonitor()
    private(set) lazy var clipboard = ClipboardMonitor()
    private(set) lazy var github = GitHubMonitor()
    private(set) lazy var downloads = DownloadMonitor()
    private(set) lazy var calendar = CalendarMonitor()
    private(set) lazy var reminders = RemindersMonitor()
    private(set) lazy var deviceBatteries = DeviceBatteryMonitor()
    private(set) lazy var mirror = MirrorCamera()
    private(set) lazy var shelf = FileShelf()
    private(set) lazy var updates = UpdateChecker()
    /// What Settings can open in the notch.
    let notchCommands = NotchCommands()
    /// Settings and Quit, unless it's hidden here or in System Settings.
    let menuBarItem = MenuBarItem()
    
    /// Opens Settings, given by `MacCoveApp`, which can open windows.
    var showSettings: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening MacCove while it's running, from the Finder, Spotlight or
    /// Launchpad, shows Settings: with the menu bar item hidden, it's the
    /// only way there.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings?()
        return false
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let nowPlaying = self.nowPlaying
        let audioRoute = AudioRouteMonitor(music: music) { [weak nowPlaying] in
            nowPlaying?.isAppleMusicPlaying == true
        }
        let xcode = XcodeBuildMonitor()
        let terminal = TerminalCommandMonitor()
        let agents = AgentMonitor()
        self.xcode = xcode
        self.terminal = terminal
        let viewModel = NotchViewModel(
            nowPlaying: nowPlaying,
            audioRoute: audioRoute,
            battery: battery,
            signIn: signIn,
            xcode: xcode,
            terminal: terminal,
            agents: agents,
            github: github,
            downloads: downloads,
            clipboard: clipboard,
            calendar: calendar,
            reminders: reminders,
            deviceBatteries: deviceBatteries,
            mirror: mirror,
            shelf: shelf
        )
        self.viewModel = viewModel
        notchCommands.showClipboardHistory = { [weak viewModel] in viewModel?.showClipboardHistory() }
        notchCommands.showTodayEvents = { [weak viewModel] in viewModel?.showTodayEvents() }
        notchCommands.showShelf = { [weak viewModel] in viewModel?.showShelf() }
        notchCommands.showDeviceBatteries = { [weak viewModel] in viewModel?.showDeviceBatteries() }
        notchCommands.showMirror = { [weak viewModel] in viewModel?.showMirror() }
        notchController = NotchWindowController(viewModel: viewModel)
        menuBarItem.showSettings = { [weak self] in self?.showSettings?() }
        menuBarItem.onOpen = { [weak self] in
            guard let self else { return }
            self.calendar.refreshPermissions()
            self.reminders.refreshPermissions()
        }
        menuBarItem.install()
        nowPlaying.start()
        battery.start()
        signIn.start()
        if ClipboardMonitor.isEnabled {
            clipboard.start()
        }
        if GitHubSetup.source != nil {
            github.start()
        }
        calendar.start()
        reminders.start()
        deviceBatteries.start()
        downloads.start()
        updates.startAutomaticChecks()
        
        // Hook events from Claude Code, Codex and Cursor, whose sessions the
        // one monitor keeps apart by the agent their path starts with.
        let bridge = AgentBridge { [weak agents] request in
            let prefixes = ["/claude/", "/codex/", "/cursor/"]
            guard prefixes.contains(where: { request.path.hasPrefix($0) }), let agents else { return .empty }
            return await agents.handle(request)
        }
        do {
            try bridge.start()
            agentBridge = bridge
        } catch {
            NSLog("MacCove couldn't open the agent socket: \(error)")
        }
        
        // maccove:// URLs, from the scripts Xcode's Behaviors run and the
        // terminal hook. Handled here rather than through SwiftUI, which has
        // no window to give them.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    func setClipboardEnabled(_ enabled: Bool) {
        if enabled {
            clipboard.start()
        } else {
            clipboard.stop()
        }
    }
    
    func showGitHubSetup() {
        GitHubSetup.showSetup(monitor: github)
    }
    
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        if xcode?.handle(url) != true {
            terminal?.handle(url)
        }
    }
}
