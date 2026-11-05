//
//  SystemSettings.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import ServiceManagement

/// Opens System Settings in front, at the pane asked for.
///
/// Since macOS 14 an app only brings another to the front when it's active
/// itself and hands over: the welcome card and the notch never make MacCove
/// active, so System Settings would open behind them, or not come forward
/// at all. So MacCove becomes active, yields to System Settings, then
/// opens it.
enum SystemSettings {
    static let bundleIdentifier = "com.apple.systempreferences"

    /// Privacy & Security, at `pane` when there's one: "Privacy_Camera"
    /// and so on.
    static func openPrivacy(_ pane: String? = nil) {
        let base = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        guard let url = URL(string: pane.map { "\(base)?\($0)" } ?? base) else { return }
        open(url)
    }

    /// General › Login Items & Extensions.
    static func openLoginItems() {
        handOver()
        SMAppService.openSystemSettingsLoginItems()
        bringForward()
    }

    static func open(_ url: URL) {
        handOver()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
        bringForward()
    }

    /// Once it's running, in case opening left it behind: up to three
    /// seconds.
    private static func bringForward() {
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
                      app.isFinishedLaunching else { continue }
                if !app.isActive {
                    _ = app.activate(options: [])
                }
                return
            }
        }
    }

    /// Whether it's the app in front, for the welcome to stay out of its
    /// way.
    static var isInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    private static func handOver() {
        NSApp.activate()
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleIdentifier)
    }
}
