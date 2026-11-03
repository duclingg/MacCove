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
            // Without it the island still shows Touch ID prompts, but not
            // the password dots or the unlock.
            if !appDelegate.signIn.hasAccessibilityAccess {
                Button("Show Password Typing and Unlocks…") {
                    appDelegate.signIn.requestAccessibilityAccess()
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
    /// Made up front, so the menu can offer Accessibility access.
    let signIn = SignInMonitor()
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let music = MusicScripting()
        let nowPlaying = NowPlayingModel(music: music)
        let audioRoute = AudioRouteMonitor(music: music) { [weak nowPlaying] in
            nowPlaying?.isAppleMusicPlaying == true
        }
        let battery = BatteryMonitor()
        notchController = NotchWindowController(
            viewModel: NotchViewModel(nowPlaying: nowPlaying, audioRoute: audioRoute, battery: battery, signIn: signIn)
        )
        nowPlaying.start()
        battery.start()
        signIn.start()
    }
}
