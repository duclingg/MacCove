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
        let nowPlaying = NowPlayingModel()
        notchController = NotchWindowController(viewModel: NotchViewModel(nowPlaying: nowPlaying))
        nowPlaying.start()
    }
}
