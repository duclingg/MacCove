import SwiftUI

@main
struct MacCoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var launchAtLogin = LaunchAtLogin()

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let music = MusicScripting()
        let nowPlaying = NowPlayingModel(music: music)
        let audioRoute = AudioRouteMonitor(music: music) { [weak nowPlaying] in
            nowPlaying?.isAppleMusicPlaying == true
        }
        let battery = BatteryMonitor()
        let signIn = SignInMonitor()
        let xcode = XcodeBuildMonitor()
        self.xcode = xcode
        notchController = NotchWindowController(
            viewModel: NotchViewModel(nowPlaying: nowPlaying, audioRoute: audioRoute, battery: battery, signIn: signIn, xcode: xcode)
        )
        nowPlaying.start()
        battery.start()
        signIn.start()

        // maccove:// URLs, from the scripts Xcode's Behaviors run. Handled
        // here rather than through SwiftUI, which has no window to give them.
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
        xcode?.handle(url)
    }
}
