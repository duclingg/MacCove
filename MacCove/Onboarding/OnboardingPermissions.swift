//
//  OnboardingPermissions.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import Network
import ServiceManagement
import SwiftUI

/// Where one of Allow a Few Things stands.
enum OnboardingAccess: Equatable {
    case notAsked
    /// macOS is asking, or MacCove is getting ready to.
    case asking
    /// Asked, with no way to tell the answer: Local Network has none.
    case asked
    case allowed
    /// The Low Power Mode helper, waiting to be turned on in Login Items.
    case waiting
    case denied
}

// MARK: - Music

/// Control Music, asked for by Allow in the welcome. Music is opened hidden
/// first if it isn't open, since only an open app can be asked about.
enum MusicAutomation {
    static func status() async -> OnboardingAccess {
        await AutomationPermission.status(of: MusicScripting.bundleIdentifier)
    }

    static func request() async -> OnboardingAccess {
        await AutomationPermission.request(MusicScripting.bundleIdentifier, openingHidden: true)
    }

    static func openSettings() {
        AutomationPermission.openSettings()
    }
}

// MARK: - Local Network

/// Find AirPlay Speakers: Local Network, which macOS asks about once per
/// app, ever. Nothing MacCove can do clears the answer, Reset All Settings
/// included, and macOS doesn't say what it was, so MacCove finds out by
/// looking for AirPlay speakers, as it does for real: a search macOS lets
/// go ahead, or speakers found, means it's allowed; a search it keeps
/// refusing means it's off. With no answer yet, that's when macOS asks.
/// (A service of MacCove's own can't be used to check: macOS refuses it
/// even when Local Network is on.)
///
/// Only once Allow has been clicked, here or in Settings › Permissions:
/// before then nothing touches the network, so nothing asks by itself.
@Observable
final class LocalNetworkProbe {
    /// One for the welcome and Settings › Permissions, so asking in one
    /// shows in the other.
    static let shared = LocalNetworkProbe()

    /// `.asking` while it looks; then `.allowed`, `.denied`, or `.asked`
    /// when nothing came back in time.
    private(set) var access: OnboardingAccess = .notAsked

    /// Every change goes through here, so Allowed always closes the guide,
    /// however it was found.
    private func set(_ access: OnboardingAccess) {
        if self.access != access {
            self.access = access
        }
        if access == .allowed {
            guideSawAllowed()
        }
    }

    @ObservationIgnored private var browser: NWBrowser?
    /// What the search said last, and the wait to see that it holds.
    @ObservationIgnored private var heard: Heard = .nothing
    @ObservationIgnored private var settling: Task<Void, Never>?

    private enum Heard {
        case nothing
        /// macOS let the search go ahead.
        case ready
        /// macOS refused it.
        case refused
    }
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?

    static let guideID = "local-network"

    /// AirPlay's, which MacCove looks for anyway and Info.plist's
    /// NSBonjourServices lists.
    nonisolated private static let serviceType = "_airplay._tcp"
    /// How macOS refuses a browse or an advertisement when Local Network
    /// is off for MacCove: `kDNSServiceErr_NoAuth` on the Mac, as its log
    /// shows, and `kDNSServiceErr_PolicyDenied`, which iOS uses.
    nonisolated private static let refusals: Set<Int32> = [-65555, -65570]

    init() {
        refresh()
    }

    /// What it is now, before anything's clicked, when that can be found
    /// out without macOS asking: once macOS has an answer, looking asks
    /// nothing. Already on shows as Allowed, with nothing to click.
    func refresh() {
        guard access == .notAsked || access == .asked else { return }
        if Self.hasAnswer || UserDefaults.standard.bool(forKey: AirPlayDeviceDirectory.hasBrowsedKey) {
            check()
        }
    }

    /// macOS keeps a record of each app it's asked about Local Network,
    /// readable by anyone: MacCove in it means it's been answered, so a
    /// search won't bring up the prompt. Reset All Settings doesn't clear
    /// it, which is why this is looked at rather than MacCove's settings.
    private static var hasAnswer: Bool {
        guard let id = Bundle.main.bundleIdentifier,
              let record = FileManager.default.contents(atPath: "/Library/Preferences/com.apple.networkextension.plist") else {
            return false
        }
        return record.range(of: Data(id.utf8)) != nil
    }

    /// Allow: macOS asks if it never has; otherwise this finds out what
    /// it was told.
    /// Allow: straight to Privacy & Security with the steps, whatever
    /// the answer was, since macOS asks only once and a reset doesn't ask
    /// again. Checking while it's open brings up macOS's own prompt on a Mac
    /// that's never been asked.
    func ask() {
        // From now on the AirPlay speakers are looked for from launch.
        UserDefaults.standard.set(true, forKey: AirPlayDeviceDirectory.hasBrowsedKey)
        turnOn()
    }

    /// Off already, and macOS won't ask again: opens Privacy & Security,
    /// the closest System Settings goes to Local Network, with the last
    /// two clicks guided. It keeps checking quietly, and ticks off once
    /// MacCove's switch is on.
    func turnOn() {
        // Already on: nothing to guide.
        guard access != .allowed else { return }
        if access == .notAsked {
            set(.asking)
        }
        let guides = NotchGuides.shared
        guides.show(NotchGuide(
            id: Self.guideID,
            icon: .symbol("network", color: .blue),
            title: "Turn on Local Network for MacCove",
            subtitle: "macOS asks only once, so it’s a switch now",
            steps: [
                NotchGuide.Step(id: "open", text: "Privacy & Security is open", detail: "In System Settings", isDone: true),
                NotchGuide.Step(id: "list", text: "Click Local Network", detail: "In the list on the right"),
                NotchGuide.Step(id: "on", text: "Turn on MacCove", detail: "Ticks off when it’s on", isWatching: true),
            ],
            actions: [
                NotchGuide.Action(title: "Open Again", finishes: false) {
                    LocalNetworkProbe.openSettings()
                },
                NotchGuide.Action(title: "Done", isPrimary: true) {},
            ]
        ))
        Self.openSettings()
        watch?.cancel()
        watch = Task { [weak self] in
            // Up to five minutes, checking straight away and then every few
            // seconds, without the row changing while it does.
            for _ in 0..<100 {
                guard !Task.isCancelled, let self, guides.isShowing(Self.guideID) else { return }
                guard self.access != .allowed else { return }
                self.check(quiet: true)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Switched on: the guide ticks it off, then leaves.
    private func guideSawAllowed() {
        let guides = NotchGuides.shared
        guard guides.isShowing(Self.guideID) else { return }
        guides.complete(step: "list", in: Self.guideID)
        guides.complete(step: "on", in: Self.guideID)
        guides.update(Self.guideID) { guide in
            guide.title = "Local Network is on"
            guide.subtitle = "AirPlay speakers show with the right icon"
        }
        watch?.cancel()
        // Long enough to see it ticked off, then it goes.
        Task {
            try? await Task.sleep(for: .seconds(3))
            guides.finish(Self.guideID)
        }
    }

    /// `quiet` checks again without the row going back to a spinner.
    private func check(quiet: Bool = false) {
        stop()
        if !quiet {
            set(.asking)
        }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            let error: NWError
            let hasFailed: Bool
            switch state {
            case .ready:
                MainActor.assumeIsolated { self?.hear(.ready) }
                return
            case let .waiting(waiting):
                error = waiting
                hasFailed = false
            case let .failed(failed):
                error = failed
                hasFailed = true
            default:
                return
            }
            let isRefused = if case let .dns(code) = error { Self.refusals.contains(code) } else { false }
            // Delivered on the main queue, as requested in start(queue:).
            MainActor.assumeIsolated {
                if isRefused {
                    self?.hear(.refused)
                } else if hasFailed {
                    // Failed some other way: no answer, rather than a
                    // spinner that never stops.
                    self?.couldNotCheck()
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard !results.isEmpty else { return }
            MainActor.assumeIsolated { self?.finish(.allowed) }
        }
        browser.start(queue: .main)
        self.browser = browser

        // Long enough to answer macOS's prompt.
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self else { return }
            if self.access == .asking {
                self.set(.asked)
            }
            self.stop()
        }
    }

    private func couldNotCheck() {
        if access == .asking {
            set(.asked)
        }
        stop()
    }

    /// Waits for what the search said to hold before going by it: a ready
    /// search for a moment means allowed, and a refusal for a few seconds
    /// means off, since macOS also refuses while its own prompt is still
    /// up, and lets the search go once it's answered.
    private func hear(_ heard: Heard) {
        self.heard = heard
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: heard == .ready ? .seconds(1.5) : .seconds(3))
            guard !Task.isCancelled, let self, self.heard == heard else { return }
            if heard == .ready {
                self.finish(.allowed)
            } else {
                self.refused()
            }
        }
    }

    private func refused() {
        set(.denied)
    }

    private func finish(_ access: OnboardingAccess) {
        stop()
        set(access)
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        settling?.cancel()
        settling = nil
        heard = .nothing
        browser?.cancel()
        browser = nil
    }

    /// Privacy & Security, where Local Network is in the list. System
    /// Settings has no address that opens Local Network itself.
    static func openSettings() {
        SystemSettings.openPrivacy()
    }
}

// MARK: - Low Power Mode helper

/// The launch daemon that switches Low Power Mode without a password.
/// Registered here rather than the first time it's used, then turned on
/// once in Login Items.
enum LowPowerModeHelperSetup {
    private static var service: SMAppService {
        SMAppService.daemon(plistName: LowPowerModeHelper.plistName)
    }

    static var access: OnboardingAccess {
        switch service.status {
        case .enabled: .allowed
        case .requiresApproval: .waiting
        default: .notAsked
        }
    }

    /// Whether this build has a helper at all.
    static var isAvailable: Bool {
        service.status != .notFound
    }

    static func install() -> OnboardingAccess {
        let service = service
        if service.status != .enabled, service.status != .requiresApproval {
            // Throws while approval is pending, which the status shows anyway.
            try? service.register()
        }
        if service.status == .requiresApproval {
            SystemSettings.openLoginItems()
        }
        return access
    }
}
