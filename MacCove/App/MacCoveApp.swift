import SwiftUI

@main
struct MacCoveApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var launchAtLogin = LaunchAtLogin()
    /// Bubbles stay clear of the front app's menus, and Stop presses Esc,
    /// only with Accessibility access.
    @State private var hasAccessibility = AppMenuExtent.isAllowed
    @AppStorage(TerminalHook.thresholdKey) private var terminalThreshold = TerminalHook.defaultThreshold
    @AppStorage(ClipboardMonitor.enabledKey) private var isClipboardEnabled = false
    @AppStorage(GitHubSetup.sourceKey) private var githubSource = ""
    /// Copies don't show, or ask every time, once macOS restricts reading
    /// the clipboard.
    @State private var isClipboardRestricted = ClipboardMonitor.isAccessRestricted

    /// Xcode runs the app to draw SwiftUI previews, which shouldn't add a
    /// menu bar item each time. Previews in JIT mode set the playgrounds
    /// variable instead of the previews one.
    private static let isRunningForPreviews = ["XCODE_RUNNING_FOR_PREVIEWS", "XCODE_RUNNING_FOR_PLAYGROUNDS"]
        .contains { ProcessInfo.processInfo.environment[$0] == "1" }

    var body: some Scene {
        MenuBarExtra("MacCove", systemImage: "capsule.tophalf.filled", isInserted: .constant(!Self.isRunningForPreviews)) {
            Button("Settings", systemImage: "gear") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings-window")
            }
            
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .onAppear {
                launchAtLogin.refresh()
                hasAccessibility = AppMenuExtent.isAllowed
                isClipboardRestricted = ClipboardMonitor.isAccessRestricted
                appDelegate.calendar.refreshPermissions()
            }
            Button("Set Up Xcode Builds…") {
                XcodeBehaviorScripts.showSetup()
            }
            Button("Set Up Terminal Commands…") {
                TerminalHook.showSetup()
            }
            Button("Set Up Claude Code…") {
                ClaudeCodeSetup.showSetup()
            }
            Button(githubSource.isEmpty ? "Connect GitHub…" : "GitHub Pull Requests…") {
                appDelegate.showGitHubSetup()
            }
            if !hasAccessibility {
                Button("Allow Accessibility Access…") {
                    AppMenuExtent.openSettings()
                }
            }
            Picker("Show Terminal Commands After", selection: Binding(
                get: { terminalThreshold },
                set: { seconds in
                    terminalThreshold = seconds
                    TerminalHook.setThreshold(seconds)
                }
            )) {
                ForEach(TerminalHook.thresholdOptions, id: \.self) { seconds in
                    Text(seconds < 60 ? "\(seconds) Seconds" : "\(seconds / 60) Minute").tag(seconds)
                }
            }
            Divider()
            // Off until asked for: copies are kept 24 hours, on this Mac
            // only, and passwords never.
            Toggle("Clipboard History", isOn: Binding(
                get: { isClipboardEnabled },
                set: { enabled in
                    isClipboardEnabled = enabled
                    appDelegate.setClipboardEnabled(enabled)
                }
            ))
            if isClipboardEnabled {
                if isClipboardRestricted {
                    Button("Allow Clipboard Access…") {
                        ClipboardMonitor.openAccessSettings()
                    }
                }
                Button("Show Clipboard History") {
                    appDelegate.showClipboardHistory()
                }
            }
            Divider()
            CalendarMenu(calendar: appDelegate.calendar) {
                appDelegate.showTodayEvents()
            }
            Divider()
            Button("Quit MacCove") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        
        Window("Settings", id: "settings-window") {
            SettingsView()
                .frame(width: 800, height: 600)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var viewModel: NotchViewModel?
    private var xcode: XcodeBuildMonitor?
    private var terminal: TerminalCommandMonitor?
    private var clipboard: ClipboardMonitor?
    private var github: GitHubMonitor?
    private var agentBridge: AgentBridge?
    /// Made when the menu bar or launch first needs it, whichever is
    /// first, so the menu can show its calendars.
    private(set) lazy var calendar = CalendarMonitor()

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
