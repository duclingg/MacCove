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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let music = MusicScripting()
        let nowPlaying = NowPlayingModel(music: music)
        let audioRoute = AudioRouteMonitor(music: music) { [weak nowPlaying] in
            nowPlaying?.isAppleMusicPlaying == true
        }
        let battery = BatteryMonitor()
        let signIn = SignInMonitor()
        notchController = NotchWindowController(
            viewModel: NotchViewModel(nowPlaying: nowPlaying, audioRoute: audioRoute, battery: battery, signIn: signIn)
        )
        nowPlaying.start()
        battery.start()
        signIn.start()
    }
}
