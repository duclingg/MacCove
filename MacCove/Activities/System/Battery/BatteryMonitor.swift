//
//  BatteryMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import Foundation
import IOKit.ps

/// The internal battery's level, power source and Low Power Mode, kept
/// current from IOKit's power source notifications. Reports the moments the
/// island announces, as the iPhone does: plugging in, dropping to 20% or
/// 10%, and Low Power Mode turning on.
@Observable
final class BatteryMonitor {
    enum Event {
        case pluggedIn
        case lowBattery
        case lowPowerModeEnabled
    }

    /// Levels that raise the low battery alert on the way down.
    static let lowBatteryThresholds = [20, 10]

    /// False on desktop Macs, which never show battery activities.
    private(set) var hasBattery = false
    /// Percent, 0 to 100.
    private(set) var level = 100
    private(set) var isPluggedIn = false
    /// Plugged in can still mean not charging, as when macOS holds the
    /// battery at 80% to preserve it.
    private(set) var isCharging = false
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// IOKit's estimates, `nil` while it's still working them out.
    private(set) var minutesToFull: Int?
    private(set) var minutesToEmpty: Int?
    private(set) var adapterWatts: Int?

    @ObservationIgnored var onEvent: ((Event) -> Void)?

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var powerStateObserver: NSObjectProtocol?
    @ObservationIgnored private var isChangingLowPowerMode = false
    @ObservationIgnored private let helper = LowPowerModeHelperClient()
    #if DEBUG
    /// A preview battery flips Low Power Mode itself instead of asking the
    /// helper.
    @ObservationIgnored private var isPreview = false
    #endif

    func start() {
        refresh(announce: false)

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // Added to the main run loop below, so this is the main thread.
            MainActor.assumeIsolated { monitor.refresh(announce: true) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeChanged() }
        }
    }

    /// Only root can change Low Power Mode, so MacCoveHelper does it. The
    /// change itself arrives through the usual notification.
    func setLowPowerMode(_ enabled: Bool) {
        #if DEBUG
        if isPreview {
            isLowPowerMode = enabled
            return
        }
        #endif
        guard !isChangingLowPowerMode else { return }
        isChangingLowPowerMode = true
        Task {
            _ = await helper.setLowPowerMode(enabled)
            isChangingLowPowerMode = false
            lowPowerModeChanged()
        }
    }

    private func refresh(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let battery = sources.lazy
                .compactMap({ IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
                .first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType })
        else {
            hasBattery = false
            return
        }

        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let capacity = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        let newLevel = capacity > 0 ? Int((Double(current) / Double(capacity) * 100).rounded()) : current
        let pluggedIn = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue

        let wasKnown = hasBattery
        let oldLevel = level
        let wasPluggedIn = isPluggedIn

        hasBattery = true
        level = min(max(newLevel, 0), 100)
        isPluggedIn = pluggedIn
        isCharging = battery[kIOPSIsChargingKey] as? Bool ?? false
        minutesToFull = Self.estimate(battery[kIOPSTimeToFullChargeKey])
        minutesToEmpty = Self.estimate(battery[kIOPSTimeToEmptyKey])
        adapterWatts = pluggedIn
            ? (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?[kIOPSPowerAdapterWattsKey] as? Int
            : nil

        guard announce, wasKnown else { return }
        if pluggedIn, !wasPluggedIn {
            onEvent?(.pluggedIn)
        } else if !pluggedIn, Self.lowBatteryThresholds.contains(where: { oldLevel > $0 && level <= $0 }) {
            onEvent?(.lowBattery)
        }
    }

    private func lowPowerModeChanged() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != isLowPowerMode else { return }
        isLowPowerMode = enabled
        if enabled, hasBattery {
            onEvent?(.lowPowerModeEnabled)
        }
    }

    /// IOKit reports -1 while it's still estimating.
    private static func estimate(_ value: Any?) -> Int? {
        guard let minutes = value as? Int, minutes > 0 else { return nil }
        return minutes
    }
}

#if DEBUG
extension BatteryMonitor {
    /// A battery that stays as given, for SwiftUI previews. Clicking Low
    /// Power Mode still flips it, so the animations can be tried.
    static func preview(
        level: Int,
        isPluggedIn: Bool = false,
        isLowPowerMode: Bool = false,
        minutesToFull: Int? = nil,
        minutesToEmpty: Int? = nil,
        adapterWatts: Int? = nil
    ) -> BatteryMonitor {
        let monitor = BatteryMonitor()
        monitor.isPreview = true
        monitor.hasBattery = true
        monitor.level = level
        monitor.isPluggedIn = isPluggedIn
        monitor.isCharging = isPluggedIn && level < 100
        monitor.isLowPowerMode = isLowPowerMode
        monitor.minutesToFull = minutesToFull
        monitor.minutesToEmpty = minutesToEmpty
        monitor.adapterWatts = adapterWatts
        return monitor
    }
}
#endif
