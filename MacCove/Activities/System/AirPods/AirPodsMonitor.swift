//
//  AirPodsMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import CoreBluetooth
import IOBluetooth

/// What a pair of headphones says about its batteries. AirPods give each
/// bud and the case; AirPods Max and most others, one level.
struct HeadphonesBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    /// The ring's level: the emptier bud, or the one battery.
    var level: Int? {
        single ?? [left, right].compactMap { $0 }.min()
    }
}

/// Bluetooth headphones while they're connected: AirPods, Beats and the
/// like.
struct ConnectedHeadphones: Identifiable, Equatable {
    /// The Bluetooth address.
    let id: String
    /// As named: "Justin's AirPods Pro".
    let name: String
    let device: AudioRoute.Device
    var battery = HeadphonesBattery()

    /// "AirPods Pro", as the iPhone says it, or the name for others.
    var title: String {
        switch device {
        case .airPods: "AirPods"
        case .airPodsPro: "AirPods Pro"
        case .airPodsMax: "AirPods Max"
        default: name
        }
    }

    var systemImage: String {
        AudioRoute(destination: name, device: device).systemImage
    }
}

/// AirPods and other Bluetooth headphones connecting, as the notch shows
/// them: the AirPods turning round beside the notch with their battery as
/// a ring, and opened up, each bud's level and the case's. They show for a
/// moment, then leave.
///
/// Connections come from IOBluetooth, which needs Bluetooth access, asked
/// for the first time it starts. The levels are IOBluetoothDevice's own,
/// not in its headers, so they're read only where it answers for them.
@Observable
final class AirPodsMonitor {
    enum Event {
        /// A pair connected, or what it shows changed.
        case started
        /// Nothing left to show.
        case ended
    }

    typealias Access = CalendarMonitor.Access

    static let enabledKey = "AirPodsEnabled"
    /// How long a pair connecting shows.
    static let shownDuration: Duration = .seconds(4)

    /// On until it's turned off in Settings, like the other System
    /// activities.
    private(set) var isEnabled = UserDefaults.standard.object(forKey: AirPodsMonitor.enabledKey) as? Bool ?? true
    private(set) var access: Access = .notDetermined
    /// Every pair connected now.
    private(set) var connected: [ConnectedHeadphones] = []
    /// The pair that just connected, while it shows.
    private(set) var shownID: String?

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the notch is open or under the cursor, so a pair waits to
    /// leave until you're done with it.
    @ObservationIgnored var isInUse: () -> Bool = { false }
    /// Connected headphones and their levels, for the device batteries
    /// list.
    @ObservationIgnored var onDevicesChange: (([PeripheralDevice]) -> Void)?

    @ObservationIgnored private let bridge = BluetoothBridge()
    @ObservationIgnored private var connectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// Made only to ask for Bluetooth access.
    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var shownTimer: Task<Void, Never>?
    @ObservationIgnored private var isShownDue = false
    @ObservationIgnored private var leaving: Task<Void, Never>?
    @ObservationIgnored private var rereading: Task<Void, Never>?
    @ObservationIgnored private var ticking: Task<Void, Never>?

    /// Levels show up a moment after the connection, sometimes a few.
    private static let rereadDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)]
    /// The list's levels are read again this often.
    private static let tickInterval: Duration = .seconds(60)
    /// Bluetooth's Audio/Video major device class.
    private static let audioDeviceClass: BluetoothDeviceClassMajor = 0x04

    var shown: ConnectedHeadphones? {
        shownID.flatMap { id in connected.first { $0.id == id } }
    }

    var isShown: Bool {
        shown != nil
    }

    // MARK: - Turning on

    /// Asks for Bluetooth access the first time it starts.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard isEnabled else { return }
        bridge.monitor = self
        refreshPermissions()
        if access == .notDetermined, centralManager == nil {
            // Asks; the answer comes back to the bridge.
            centralManager = CBCentralManager(delegate: bridge, queue: nil)
        }
    }

    /// Turned off: nothing more shows.
    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for notification in disconnectNotifications.values {
            notification.unregister()
        }
        disconnectNotifications = [:]
        ticking?.cancel()
        ticking = nil
        rereading?.cancel()
        connected = []
        onDevicesChange?([])
        if shownID != nil {
            endShown()
            onEvent?(.ended)
        }
    }

    /// When Settings opens: access may have been granted or taken away in
    /// System Settings since.
    func refreshPermissions() {
        access = switch CBManager.authorization {
        case .allowedAlways: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        if isEnabled, access == .granted, connectNotification == nil {
            begin()
        } else if access != .granted, connectNotification != nil {
            stop()
        }
    }

    static func openAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth") else { return }
        NSWorkspace.shared.open(url)
    }

    private func begin() {
        bridge.monitor = self
        ticking?.cancel()
        // Those already connected are listed, but don't show.
        for device in IOBluetoothDevice.pairedDevices() ?? [] {
            guard let device = device as? IOBluetoothDevice, device.isConnected() else { continue }
            add(device, announce: false)
        }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: bridge,
            selector: #selector(BluetoothBridge.deviceConnected(_:device:))
        )
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                self.readLevels()
            }
        }
    }

    // MARK: - Connecting

    fileprivate func deviceConnected(_ device: IOBluetoothDevice) {
        add(device, announce: true)
    }

    fileprivate func deviceDisconnected(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        disconnectNotifications.removeValue(forKey: address)?.unregister()
        connected.removeAll { $0.id == address }
        devicesChanged()
        if shownID == address {
            endShown()
            onEvent?(.ended)
        }
    }

    private func add(_ device: IOBluetoothDevice, announce: Bool) {
        guard let address = device.addressString, Self.isHeadphones(device) else { return }
        // Already here: macOS also tells of those connected as this
        // starts.
        guard !connected.contains(where: { $0.id == address }) else { return }
        let name = device.name ?? "Headphones"
        connected.append(ConnectedHeadphones(
            id: address,
            name: name,
            device: AudioRoute.bluetoothDevice(named: name),
            battery: Self.battery(of: device)
        ))
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: bridge,
            selector: #selector(BluetoothBridge.deviceDisconnected(_:device:))
        )
        devicesChanged()
        guard announce else { return }
        show(address)
        rereading?.cancel()
        rereading = Task { [weak self] in
            for delay in Self.rereadDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.readLevels()
            }
        }
    }

    private static func isHeadphones(_ device: IOBluetoothDevice) -> Bool {
        let name = device.name?.lowercased() ?? ""
        return device.deviceClassMajor == audioDeviceClass || name.contains("airpods") || name.contains("beats")
    }

    // MARK: - Levels

    private func readLevels() {
        var changed = false
        for index in connected.indices {
            guard let device = IOBluetoothDevice(addressString: connected[index].id) else { continue }
            let battery = Self.battery(of: device)
            if battery != connected[index].battery {
                connected[index].battery = battery
                changed = true
            }
        }
        if changed {
            devicesChanged()
        }
    }

    private static func battery(of device: IOBluetoothDevice) -> HeadphonesBattery {
        HeadphonesBattery(
            left: percent(device, "batteryPercentLeft"),
            right: percent(device, "batteryPercentRight"),
            caseLevel: percent(device, "batteryPercentCase"),
            single: percent(device, "batteryPercentSingle")
        )
    }

    /// 0 means it doesn't know, or that part isn't there, as for a case
    /// left at home.
    private static func percent(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = (device.value(forKey: key) as? NSNumber)?.intValue,
              (1...100).contains(value) else { return nil }
        return value
    }

    private func devicesChanged() {
        onDevicesChange?(connected.compactMap { headphones in
            guard let level = headphones.battery.level else { return nil }
            return PeripheralDevice(
                id: headphones.id,
                name: headphones.title,
                kind: .headphones(headphones.device),
                level: level,
                isCharging: false
            )
        })
    }

    // MARK: - What shows

    private func show(_ id: String) {
        leaving?.cancel()
        shownID = id
        isShownDue = false
        shownTimer?.cancel()
        shownTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.shownDuration)
            guard !Task.isCancelled, let self else { return }
            self.isShownDue = true
            self.leaveIfDue()
        }
        onEvent?(.started)
    }

    private func endShown() {
        shownTimer?.cancel()
        shownTimer = nil
        isShownDue = false
        shownID = nil
    }

    /// Once it has had its time, it leaves as the notch closes, unless it's
    /// open or under the cursor; then it waits to be asked again.
    func leaveIfDue(after delay: Duration = .zero) {
        guard isShownDue, shownID != nil else { return }
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isInUse(), self.isShownDue else { return }
            self.endShown()
            self.onEvent?(.ended)
        }
    }
}

/// IOBluetooth and Core Bluetooth call back through Objective-C selectors
/// and delegates, so they go through here.
private final class BluetoothBridge: NSObject, CBCentralManagerDelegate {
    weak var monitor: AirPodsMonitor?

    @objc func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        monitor?.deviceConnected(device)
    }

    @objc func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        monitor?.deviceDisconnected(device)
    }

    /// Bluetooth access answered, at the prompt or already.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.monitor?.refreshPermissions()
        }
    }
}

#if DEBUG
extension AirPodsMonitor {
    /// Shows the pair given and stays that way, for SwiftUI previews.
    static func preview(_ headphones: ConnectedHeadphones) -> AirPodsMonitor {
        let monitor = AirPodsMonitor()
        monitor.connected = [headphones]
        monitor.shownID = headphones.id
        return monitor
    }
}
#endif
