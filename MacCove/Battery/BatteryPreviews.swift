#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func charging(_ battery: BatteryMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.chargingWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        ChargingCompactView(battery: battery, notchSize: notch)
    }
}

private func lowBattery(_ battery: BatteryMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + NotchViewModel.alertBodyHeight),
        cornerRadius: NotchViewModel.alertCornerRadius,
        isLifted: true
    ) {
        LowBatteryAlertView(battery: battery, notchHeight: notch.height)
    }
}

private func details(_ battery: BatteryMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + BatteryExpandedView.bodyHeight),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        BatteryExpandedView(battery: battery, notchHeight: notch.height)
    }
}

// MARK: - Charging pill

#Preview("Charging") {
    charging(.preview(level: 65, isPluggedIn: true))
}

#Preview("Charging · Full") {
    charging(.preview(level: 100, isPluggedIn: true))
}

#Preview("Charging · Low Power Mode") {
    charging(.preview(level: 24, isPluggedIn: true, isLowPowerMode: true))
}

// MARK: - Low battery alert (click the battery to toggle)

#Preview("Low Battery · Turn On Low Power Mode") {
    lowBattery(.preview(level: 20, minutesToEmpty: 70))
}

#Preview("Low Battery · Low Power Mode Enabled") {
    lowBattery(.preview(level: 20, isLowPowerMode: true, minutesToEmpty: 100))
}

#Preview("Low Battery · 10%") {
    lowBattery(.preview(level: 10, minutesToEmpty: 32))
}

// MARK: - Battery details

#Preview("Details · Charging") {
    details(.preview(level: 65, isPluggedIn: true, minutesToFull: 72, adapterWatts: 96))
}

#Preview("Details · Fully Charged") {
    details(.preview(level: 100, isPluggedIn: true, adapterWatts: 96))
}

#Preview("Details · Low Power Mode") {
    details(.preview(level: 20, isLowPowerMode: true, minutesToEmpty: 100))
}

#Preview("Details · On Battery") {
    details(.preview(level: 54, minutesToEmpty: 245))
}
#endif
