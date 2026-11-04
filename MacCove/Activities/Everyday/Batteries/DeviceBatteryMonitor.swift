//
//  DeviceBatteryMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import Foundation
import GameController
import IOKit

/// Something connected to the Mac that runs on a battery: a mouse,
/// keyboard, trackpad or game controller.
struct PeripheralDevice: Identifiable, Equatable {
    enum Kind: Equatable {
        case mouse
        case keyboard
        case trackpad
        case controller
        case other
    }

    /// The Bluetooth address or serial number, so the same device is
    /// known again as its level changes.
    let id: String
    let name: String
    let kind: Kind
    /// Percent, 0 to 100.
    let level: Int
    let isCharging: Bool

    var systemImage: String {
        switch kind {
        case .mouse: "computermouse.fill"
        case .keyboard: "keyboard.fill"
        case .trackpad: "rectangle.and.hand.point.up.left.fill"
        case .controller: "gamecontroller.fill"
        case .other: "dot.radiowaves.right"
        }
    }

    /// Mice, keyboards and trackpads only say what they are in their name.
    static func kind(forProduct name: String) -> Kind {
        let lowercased = name.lowercased()
        if lowercased.contains("mouse") { return .mouse }
        if lowercased.contains("trackpad") { return .trackpad }
        if lowercased.contains("keyboard") { return .keyboard }
        return .other
    }
}

/// The batteries of mice, keyboards, trackpads and game controllers, as
/// the notch shows them: a warning at 10% and again at 5%, with Dismiss
/// and Remind Me Tonight; a device's level for a moment as it connects or
/// starts charging; and every device's level when one of those is opened.
///
/// Apple's own accessories report `BatteryPercent` in the IORegistry, on
/// their `AppleDeviceManagementHIDEventService`; game controllers through
/// GameController. Neither says when a level changes, so they're read
/// again every minute, and whenever a device comes or goes.
@Observable
final class DeviceBatteryMonitor {
    enum Event {
        /// Something new to show, or what's shown moved on.
        case started
        /// Nothing left to show.
        case ended
    }

    enum Phase: Equatable {
        /// A device is at 10% or less, until it's dismissed or charged.
        case low
        /// One just connected: its level, for a moment.
        case connected
        /// One just started charging, for a moment.
        case charging
        /// Every device, opened from Settings.
        case list
    }

    static let enabledKey = "DeviceBatteriesEnabled"
    /// Levels that warn on the way down, once each.
    static let lowThresholds = [10, 5]
    /// How long a device connecting or charging shows.
    static let momentDuration: Duration = .seconds(4)
    /// When Remind Me Tonight shows the warning again.
    static let tonightHour = 20

    /// On until it's turned off in Settings.
    private(set) var isEnabled = UserDefaults.standard.object(forKey: DeviceBatteryMonitor.enabledKey) as? Bool ?? true
    /// Mice, keyboards, trackpads and controllers, by name.
    private(set) var devices: [PeripheralDevice] = []
    /// Low and not yet dismissed, the first warned first.
    private(set) var lowDeviceIDs: [String] = []
    /// The device connecting or charging, while it shows.
    private(set) var moment: (phase: Phase, id: String)?
    /// Every device, asked for from Settings, until the notch closes.
    private(set) var isListOpen = false

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the notch is open or under the cursor, when a moment waits
    /// to leave until you're done with it.
    @ObservationIgnored var isInUse: () -> Bool = { false }

    /// The lowest level each device has been warned at, until it's charged
    /// past the first again.
    @ObservationIgnored private var warnedAt: [String: Int] = [:]
    /// Remind Me Tonight: when each warning comes back.
    @ObservationIgnored private var snoozedUntil: [String: Date] = [:]
    @ObservationIgnored private var hasRead = false
    @ObservationIgnored private var isMomentDue = false
    @ObservationIgnored private var momentTimer: Task<Void, Never>?
    @ObservationIgnored private var leaving: Task<Void, Never>?
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var rereading: Task<Void, Never>?
    @ObservationIgnored private var notificationPort: IONotificationPortRef?
    @ObservationIgnored private var matchIterators: [io_iterator_t] = []
    @ObservationIgnored private var controllerObservers: [any NSObjectProtocol] = []
    /// What was last shown, to say when that changes.
    @ObservationIgnored private var shownKey: String?

    private static let serviceClass = "AppleDeviceManagementHIDEventService"
    /// Levels drift slowly, so a minute is soon enough.
    private static let tickInterval: Duration = .seconds(60)

    var phase: Phase? {
        if !lowDevices.isEmpty { return .low }
        if let moment { return moment.phase }
        return isListOpen ? .list : nil
    }

    var isShown: Bool {
        phase != nil
    }

    /// Low and not dismissed, in the order they were warned about.
    var lowDevices: [PeripheralDevice] {
        lowDeviceIDs.compactMap { id in devices.first { $0.id == id } }
    }

    /// The one the pill is about: the lowest, or the one connecting or
    /// charging.
    var featured: PeripheralDevice? {
        if let low = lowDevices.min(by: { $0.level < $1.level }) { return low }
        guard let moment else { return nil }
        return devices.first { $0.id == moment.id }
    }

    static func isLow(_ device: PeripheralDevice) -> Bool {
        !device.isCharging && device.level <= lowThresholds[0]
    }

    // MARK: - Turning on

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard isEnabled, ticking == nil else { return }
        watchForDevices()
        read()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                self.read()
            }
        }
    }

    /// Turned off: nothing more shows.
    func stop() {
        ticking?.cancel()
        ticking = nil
        rereading?.cancel()
        for iterator in matchIterators {
            IOObjectRelease(iterator)
        }
        matchIterators = []
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        notificationPort = nil
        for observer in controllerObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        controllerObservers = []
        hasRead = false
        devices = []
        lowDeviceIDs = []
        warnedAt = [:]
        snoozedUntil = [:]
        endMoment()
        isListOpen = false
        leaving?.cancel()
        update()
    }

    // MARK: - Watching for devices

    /// Accessories coming and going in the IORegistry, and controllers
    /// connecting, have everything read again. A new accessory's level
    /// can take a few seconds to appear, so it's read again after that.
    private func watchForDevices() {
        guard notificationPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        notificationPort = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            // Emptied, or no more notifications come.
            var service = IOIteratorNext(iterator)
            while service != 0 {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let context else { return }
            let monitor = Unmanaged<DeviceBatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // Delivered on the main queue, set above.
            MainActor.assumeIsolated { monitor.devicesChanged() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // Each call takes its own matching dictionary.
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching(Self.serviceClass), callback, context, &iterator) == KERN_SUCCESS else { continue }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            matchIterators.append(iterator)
        }

        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            controllerObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            })
        }
    }

    private func devicesChanged() {
        read()
        rereading?.cancel()
        rereading = Task { [weak self] in
            for delay in [Duration.seconds(2), .seconds(6)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.read()
            }
        }
    }

    // MARK: - Reading levels

    private func read() {
        guard isEnabled else { return }
        var found = Self.accessories()
        for controller in Self.controllers() where !found.contains(where: { $0.id == controller.id }) {
            found.append(controller)
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let previous = devices
        let wasRead = hasRead
        hasRead = true
        if found != devices {
            devices = found
        }
        let now = Date.now

        for device in found {
            let before = previous.first { $0.id == device.id }
            if !Self.isLow(device) {
                // Charged, or charging: the warnings start over.
                warnedAt[device.id] = nil
                snoozedUntil[device.id] = nil
                lowDeviceIDs.removeAll { $0 == device.id }
            } else if let threshold = Self.lowThresholds.last(where: { device.level <= $0 }),
                      threshold < (warnedAt[device.id] ?? .max) {
                // Down past a level not yet warned about, the lowest one
                // it's at, so a device first seen at 4% warns just once.
                warnedAt[device.id] = threshold
                snoozedUntil[device.id] = nil
                if !lowDeviceIDs.contains(device.id) {
                    lowDeviceIDs.append(device.id)
                }
            } else if let until = snoozedUntil[device.id], until <= now {
                snoozedUntil[device.id] = nil
                if !lowDeviceIDs.contains(device.id) {
                    lowDeviceIDs.append(device.id)
                }
            }

            // Not for those already there when MacCove starts.
            guard wasRead else { continue }
            if before == nil {
                showMoment(.connected, for: device)
            } else if device.isCharging, before?.isCharging == false {
                showMoment(.charging, for: device)
            }
        }

        // Gone: nothing left to warn about.
        lowDeviceIDs.removeAll { id in !found.contains { $0.id == id } }
        if let moment, !devices.contains(where: { $0.id == moment.id }) {
            endMoment()
        }
        update()
    }

    /// Apple's mice, keyboards and trackpads. One device can have more
    /// than one service, so each is taken once, by address.
    private static func accessories() -> [PeripheralDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [PeripheralDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let level = (property("BatteryPercent") as? NSNumber)?.intValue else { continue }
            let name = (property("Product") as? String) ?? "Accessory"
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            let id = (property("DeviceAddress") as? String) ?? (property("SerialNumber") as? String) ?? "registry:\(entryID)"
            guard !found.contains(where: { $0.id == id }) else { continue }
            // Bit 1 is set while it's on its cable and charging.
            let flags = (property("BatteryStatusFlags") as? NSNumber)?.intValue ?? 0
            found.append(PeripheralDevice(
                id: id,
                name: name,
                kind: PeripheralDevice.kind(forProduct: name),
                level: min(max(level, 0), 100),
                isCharging: flags & 0b10 != 0
            ))
        }
        return found
    }

    /// Game controllers that report a battery.
    private static func controllers() -> [PeripheralDevice] {
        GCController.controllers().compactMap { controller in
            guard let battery = controller.battery, battery.batteryState != .unknown else { return nil }
            return PeripheralDevice(
                id: "controller:\(UInt(bitPattern: ObjectIdentifier(controller).hashValue))",
                name: controller.vendorName ?? "Game Controller",
                kind: .controller,
                level: min(max(Int((battery.batteryLevel * 100).rounded()), 0), 100),
                isCharging: battery.batteryState == .charging
            )
        }
    }

    // MARK: - What shows

    private func showMoment(_ phase: Phase, for device: PeripheralDevice) {
        moment = (phase, device.id)
        isMomentDue = false
        momentTimer?.cancel()
        momentTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.momentDuration)
            guard !Task.isCancelled, let self else { return }
            self.isMomentDue = true
            self.leaveIfDue()
        }
    }

    private func endMoment() {
        momentTimer?.cancel()
        momentTimer = nil
        isMomentDue = false
        moment = nil
    }

    private func update() {
        let key = currentKey
        guard key != shownKey else { return }
        let wasShown = shownKey != nil
        shownKey = key
        if key != nil {
            onEvent?(.started)
        } else if wasShown {
            onEvent?(.ended)
        }
    }

    /// One for each thing shown, so the notch hears when it changes.
    private var currentKey: String? {
        switch phase {
        case .low?: featured.map { "low:\($0.id)" }
        case .connected?, .charging?: moment.map { "\($0.phase):\($0.id)" }
        case .list?: "list"
        case nil: nil
        }
    }

    // MARK: - Actions

    /// The low device shown, until the next level down.
    func dismiss() {
        guard let device = featured, phase == .low else { return }
        lowDeviceIDs.removeAll { $0 == device.id }
        update()
    }

    /// Whether Remind Me Tonight still means tonight, or is an hour away
    /// by now.
    static func remindsTonight(at now: Date = .now) -> Bool {
        Calendar.current.component(.hour, from: now) < tonightHour - 1
    }

    /// The low device shown, back at 8 PM, or in an hour once it's late.
    func remindLater() {
        guard let device = featured, phase == .low else { return }
        let now = Date.now
        let calendar = Calendar.current
        let until = Self.remindsTonight(at: now)
            ? calendar.date(bySettingHour: Self.tonightHour, minute: 0, second: 0, of: now)
            : calendar.date(byAdding: .hour, value: 1, to: now)
        snoozedUntil[device.id] = until
        lowDeviceIDs.removeAll { $0 == device.id }
        update()
    }

    /// From Settings: every device, until the notch closes.
    func showList() {
        leaving?.cancel()
        isListOpen = true
        update()
    }

    /// A moment that has had its time, and the list, leave once the notch
    /// closes, unless it's open or under the cursor; then they wait to be
    /// asked again.
    func leaveIfDue(after delay: Duration = .zero) {
        guard (isMomentDue && moment != nil) || isListOpen else { return }
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isInUse() else { return }
            if self.isMomentDue {
                self.endMoment()
            }
            self.isListOpen = false
            self.update()
        }
    }
}

#if DEBUG
extension DeviceBatteryMonitor {
    /// Shows what's given and stays that way, for SwiftUI previews.
    static func preview(
        devices: [PeripheralDevice],
        low: [String] = [],
        moment: (phase: Phase, id: String)? = nil,
        isListOpen: Bool = false
    ) -> DeviceBatteryMonitor {
        let monitor = DeviceBatteryMonitor()
        monitor.devices = devices
        monitor.lowDeviceIDs = low
        monitor.moment = moment
        monitor.isListOpen = isListOpen
        return monitor
    }
}
#endif
