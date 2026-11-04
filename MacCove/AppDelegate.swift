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
    private var clipboard: ClipboardMonitor?
    private var github: GitHubMonitor?
    private var agentBridge: AgentBridge?
    private(set) lazy var calendar = CalendarMonitor()
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let music = MusicScripting()
        let nowPlaying = NowPlayingModel(music: music)
        let audioRoute = AudioRouteMonitor(music: music) { [weak nowPlaying] in
            nowPlaying?.isAppleMusicPlaying == true
        }
        let battery = BatteryMonitor()
        let signIn = SignInMonitor()
        let xcode = XcodeBuildMonitor()
        let terminal = TerminalCommandMonitor()
        let claude = ClaudeCodeMonitor()
        let github = GitHubMonitor()
        let clipboard = ClipboardMonitor()
        self.xcode = xcode
        self.terminal = terminal
        self.github = github
        self.clipboard = clipboard
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
            calendar: calendar
        )
        self.viewModel = viewModel
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
            clipboard?.start()
        } else {
            clipboard?.stop()
        }
    }
    
    func showClipboardHistory() {
        viewModel?.showClipboardHistory()
    }
    
    func showTodayEvents() {
        viewModel?.showTodayEvents()
    }
    
    func showGitHubSetup() {
        guard let github else { return }
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
