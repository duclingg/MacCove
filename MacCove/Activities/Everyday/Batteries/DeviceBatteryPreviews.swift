//
//  DeviceBatteryPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private let mouse = PeripheralDevice(id: "mouse", name: "Magic Mouse", kind: .mouse, level: 10, isCharging: false)
private let chargingMouse = PeripheralDevice(id: "mouse", name: "Magic Mouse", kind: .mouse, level: 12, isCharging: true)
private let keyboard = PeripheralDevice(id: "keyboard", name: "Magic Keyboard", kind: .keyboard, level: 64, isCharging: false)
private let controller = PeripheralDevice(id: "controller", name: "Wireless Controller", kind: .controller, level: 35, isCharging: false)

private func compact(_ batteries: DeviceBatteryMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: DeviceBatteryCompactView.width(for: batteries, notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        DeviceBatteryCompactView(batteries: batteries, notchSize: notch)
    }
}

private func expanded(_ batteries: DeviceBatteryMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + DeviceBatteryExpandedView.bodyHeight(for: batteries)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        DeviceBatteryExpandedView(batteries: batteries, notchHeight: notch.height)
    }
}

#Preview("Low battery") {
    compact(.preview(devices: [mouse, keyboard], low: [mouse.id]))
}

#Preview("Low, expanded") {
    expanded(.preview(devices: [mouse, keyboard], low: [mouse.id]))
}

#Preview("Connected") {
    compact(.preview(devices: [keyboard], moment: (.connected, keyboard.id)))
}

#Preview("Charging") {
    compact(.preview(devices: [chargingMouse], moment: (.charging, chargingMouse.id)))
}

#Preview("Every connected device") {
    expanded(.preview(
        devices: [mouse, keyboard, controller],
        moment: (.connected, keyboard.id)
    ))
}
#endif
