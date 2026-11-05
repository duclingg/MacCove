//
//  AirPlayDeviceDirectory.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import Foundation
import Network

/// The AirPlay devices on the local network: each one's model, and whether
/// it's currently receiving audio.
///
/// Core Audio doesn't say which device the Mac is AirPlaying to: the output
/// is just called "AirPlay". The devices themselves announce more over
/// Bonjour (`_airplay._tcp`): `model` (`AudioAccessory5,1` is a HomePod mini)
/// and status `flags`, which include a bit for an active receiver session.
///
/// Browsing needs the user's Local Network permission, which is only asked
/// for by Allow in the welcome: audio going to AirPlay never asks by itself.
/// Once asked, it starts at launch, so devices are already known when audio
/// switches over.
@Observable
final class AirPlayDeviceDirectory {
    nonisolated struct Device: Equatable {
        var name: String
        var model: String?
        /// Can show video: a TV, or a box like Apple TV plugged into one.
        var hasScreen: Bool = false
        var isReceiving: Bool
    }

    /// Lowercased service name → device.
    private var devices: [String: Device] = [:]

    /// The device that most recently said it was receiving, kept across
    /// launches. Most people AirPlay to the same speaker, so it's a good guess
    /// while a device's announcement catches up with a new session.
    private(set) var lastReceivingDevice: Device?

    @ObservationIgnored private var browser: NWBrowser?

    /// Set in `flags` while a device is playing audio from a sender. Seen
    /// flipping on a HomePod mini as the Mac starts and stops AirPlaying to it.
    nonisolated private static let receiverSessionActiveFlag: UInt64 = 0x2_0000
    /// Set in `features` by devices that can show video (AirPlay screen
    /// support): set on Apple TVs and TVs like a Roku TV, not on HomePods.
    nonisolated private static let screenFeature: UInt64 = 0x80

    /// Set once Local Network has been asked for, in the welcome, after
    /// which browsing starts at launch.
    static let hasBrowsedKey = DefaultsKey.hasBrowsed

    private enum DefaultsKey {
        static let hasBrowsed = "AirPlayDeviceDirectory.hasBrowsed"
        static let lastReceiverName = "AirPlayDeviceDirectory.lastReceiverName"
        static let lastReceiverModel = "AirPlayDeviceDirectory.lastReceiverModel"
        static let lastReceiverHasScreen = "AirPlayDeviceDirectory.lastReceiverHasScreen"
    }

    init() {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: DefaultsKey.lastReceiverName) {
            lastReceivingDevice = Device(
                name: name,
                model: defaults.string(forKey: DefaultsKey.lastReceiverModel),
                hasScreen: defaults.bool(forKey: DefaultsKey.lastReceiverHasScreen),
                isReceiving: true
            )
        }
        if defaults.bool(forKey: DefaultsKey.hasBrowsed) {
            startIfNeeded()
        }
    }

    func device(named name: String) -> Device? {
        devices[name.lowercased()]
    }

    /// Devices currently playing audio, sorted by name.
    var receivingDevices: [Device] {
        devices.values.filter(\.isReceiving).sorted { $0.name < $1.name }
    }

    /// Browses once Local Network has been asked for; until then, does
    /// nothing, so macOS's prompt never comes out of the blue.
    func startIfNeeded() {
        guard browser == nil, UserDefaults.standard.bool(forKey: DefaultsKey.hasBrowsed) else { return }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: Device] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(record) = result.metadata else { continue }
                found[name.lowercased()] = Device(
                    name: name,
                    model: record["model"],
                    hasScreen: Self.hasScreen(features: record["features"]),
                    isReceiving: Self.isReceiving(flags: record["flags"])
                )
            }
            let snapshot = found
            // Delivered on the main queue, as requested in start(queue:).
            MainActor.assumeIsolated { self?.update(snapshot) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func update(_ found: [String: Device]) {
        devices = found
        guard let receiver = receivingDevices.first, receiver != lastReceivingDevice else { return }
        lastReceivingDevice = receiver
        UserDefaults.standard.set(receiver.name, forKey: DefaultsKey.lastReceiverName)
        UserDefaults.standard.set(receiver.model, forKey: DefaultsKey.lastReceiverModel)
        UserDefaults.standard.set(receiver.hasScreen, forKey: DefaultsKey.lastReceiverHasScreen)
    }

    nonisolated private static func isReceiving(flags: String?) -> Bool {
        hexValue(flags).map { $0 & receiverSessionActiveFlag != 0 } ?? false
    }

    /// `features` is one or two hex words, "0x7F8AD0,0x38BCF46"; the screen
    /// bit is in the first.
    nonisolated private static func hasScreen(features: String?) -> Bool {
        let firstWord = features?.split(separator: ",").first.map(String.init)
        return hexValue(firstWord).map { $0 & screenFeature != 0 } ?? false
    }

    /// Parses hex such as "0xb8c04".
    nonisolated private static func hexValue(_ text: String?) -> UInt64? {
        guard var hex = text?.lowercased() else { return nil }
        if hex.hasPrefix("0x") {
            hex.removeFirst(2)
        }
        return UInt64(hex, radix: 16)
    }
}
