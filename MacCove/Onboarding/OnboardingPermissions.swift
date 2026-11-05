//
//  OnboardingPermissions.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import Network
import ServiceManagement

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

/// Find AirPlay Speakers: Local Network, which macOS asks about the first
/// time MacCove browses for AirPlay devices. macOS doesn't say what was
/// answered, so it's Allowed once a device turns up and Denied once the
/// browse is refused; otherwise just Asked.
@Observable
final class LocalNetworkProbe {
    private(set) var access: OnboardingAccess

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// `kDNSServiceErr_PolicyDenied`: Local Network is off for MacCove.
    nonisolated private static let policyDenied: Int32 = -65570

    init() {
        access = UserDefaults.standard.bool(forKey: AirPlayDeviceDirectory.hasBrowsedKey) ? .asked : .notAsked
    }

    func ask() {
        guard browser == nil else { return }
        // Now asked, the AirPlay speakers are looked for from launch.
        UserDefaults.standard.set(true, forKey: AirPlayDeviceDirectory.hasBrowsedKey)
        access = .asked
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            guard case let .waiting(error) = state, case let .dns(code) = error, code == Self.policyDenied else { return }
            // Delivered on the main queue, as requested in start(queue:).
            MainActor.assumeIsolated { self?.finish(.denied) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard !results.isEmpty else { return }
            MainActor.assumeIsolated { self?.finish(.allowed) }
        }
        browser.start(queue: .main)
        self.browser = browser
        // Long enough to answer macOS and for speakers to answer back.
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        timeout?.cancel()
        browser?.cancel()
        browser = nil
    }

    private func finish(_ access: OnboardingAccess) {
        self.access = access
        stop()
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
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
            SMAppService.openSystemSettingsLoginItems()
        }
        return access
    }
}
