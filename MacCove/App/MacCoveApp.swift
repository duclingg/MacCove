import SwiftUI

@main
struct MacCoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("MacCove", systemImage: "capsule.tophalf.filled") {
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
        notchController = NotchWindowController(viewModel: NotchViewModel(nowPlaying: nowPlaying, audioRoute: audioRoute))
        nowPlaying.start()
    }
}
