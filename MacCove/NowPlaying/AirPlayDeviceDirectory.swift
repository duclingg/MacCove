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
/// Browsing needs the user's Local Network permission, so the first time it
/// only starts once audio actually goes to AirPlay. After that it starts at
/// launch, so devices are already known when audio switches over.
@Observable
final class AirPlayDeviceDirectory {
    nonisolated struct Device: Equatable {
        var name: String
        var model: String?
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

    private enum DefaultsKey {
        static let hasBrowsed = "AirPlayDeviceDirectory.hasBrowsed"
        static let lastReceiverName = "AirPlayDeviceDirectory.lastReceiverName"
        static let lastReceiverModel = "AirPlayDeviceDirectory.lastReceiverModel"
    }

    init() {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: DefaultsKey.lastReceiverName) {
            lastReceivingDevice = Device(name: name, model: defaults.string(forKey: DefaultsKey.lastReceiverModel), isReceiving: true)
        }
        if defaults.bool(forKey: DefaultsKey.hasBrowsed) {
            startIfNeeded()
        }
    }

    func model(named name: String) -> String? {
        devices[name.lowercased()]?.model
    }

    /// Devices currently playing audio, sorted by name.
    var receivingDevices: [Device] {
        devices.values.filter(\.isReceiving).sorted { $0.name < $1.name }
    }

    func startIfNeeded() {
        guard browser == nil else { return }
        UserDefaults.standard.set(true, forKey: DefaultsKey.hasBrowsed)

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: Device] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(record) = result.metadata else { continue }
                found[name.lowercased()] = Device(
                    name: name,
                    model: record["model"],
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
    }

    /// `flags` is hex, such as "0xb8c04".
    nonisolated private static func isReceiving(flags: String?) -> Bool {
        guard var hex = flags?.lowercased() else { return false }
        if hex.hasPrefix("0x") {
            hex.removeFirst(2)
        }
        guard let value = UInt64(hex, radix: 16) else { return false }
        return value & receiverSessionActiveFlag != 0
    }
}
