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
    private(set) lazy var calendar = CalendarMonitor()
    private(set) lazy var shelf = FileShelf()
    private(set) lazy var updates = UpdateChecker()
    /// What Settings can open in the notch.
    let notchCommands = NotchCommands()
    
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
        let claude = ClaudeCodeMonitor()
        self.xcode = xcode
        self.terminal = terminal
        let viewModel = NotchViewModel(
            nowPlaying: nowPlaying,
            audioRoute: audioRoute,
            battery: battery,
            signIn: signIn,
            xcode: xcode,
            terminal: terminal,
            claude: claude,
            github: github,
            clipboard: clipboard,
            calendar: calendar,
            shelf: shelf
        )
        self.viewModel = viewModel
        notchCommands.showClipboardHistory = { [weak viewModel] in viewModel?.showClipboardHistory() }
        notchCommands.showTodayEvents = { [weak viewModel] in viewModel?.showTodayEvents() }
        notchCommands.showShelf = { [weak viewModel] in viewModel?.showShelf() }
        notchController = NotchWindowController(viewModel: viewModel)
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
        updates.startAutomaticChecks()
        
        // Hook events from Claude Code, by the agent they're for.
        let bridge = AgentBridge { [weak claude] request in
            guard request.path.hasPrefix("/claude/"), let claude else { return .empty }
            return await claude.handle(request)
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
