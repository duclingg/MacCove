import SwiftUI

@main
struct MacCoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var launchAtLogin = LaunchAtLogin()
    @AppStorage(TerminalHook.thresholdKey) private var terminalThreshold = TerminalHook.defaultThreshold

    var body: some Scene {
        MenuBarExtra("MacCove", systemImage: "capsule.tophalf.filled") {
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .onAppear { launchAtLogin.refresh() }
            Button("Set Up Xcode Builds…") {
                XcodeBehaviorScripts.showSetup()
            }
            Button("Set Up Terminal Commands…") {
                TerminalHook.showSetup()
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
            Button("Quit MacCove") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var xcode: XcodeBuildMonitor?
    private var terminal: TerminalCommandMonitor?

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
        self.xcode = xcode
        self.terminal = terminal
        notchController = NotchWindowController(
            viewModel: NotchViewModel(
                nowPlaying: nowPlaying,
                audioRoute: audioRoute,
                battery: battery,
                signIn: signIn,
                xcode: xcode,
                terminal: terminal
            )
        )
        nowPlaying.start()
        battery.start()
        signIn.start()

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

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        if xcode?.handle(url) != true {
            terminal?.handle(url)
        }
    }
}
