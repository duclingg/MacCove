//
//  AirPodsPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private let airPodsPro = ConnectedHeadphones(
    id: "airpods-pro",
    name: "Justin's AirPods Pro",
    device: .airPodsPro,
    battery: HeadphonesBattery(left: 88, right: 86, caseLevel: 72)
)

private let airPodsMax = ConnectedHeadphones(
    id: "airpods-max",
    name: "Justin's AirPods Max",
    device: .airPodsMax,
    battery: HeadphonesBattery(single: 80)
)

private func compact(_ airPods: AirPodsMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.compactWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        AirPodsCompactView(airPods: airPods, notchSize: notch)
    }
}

private func expanded(_ airPods: AirPodsMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.expandedWidth, height: notch.height + AirPodsExpandedView.bodyHeight(for: airPods)),
        cornerRadius: NotchViewModel.expandedCornerRadius,
        isLifted: true
    ) {
        AirPodsExpandedView(airPods: airPods, notchHeight: notch.height)
    }
}

#Preview("Connected") {
    compact(.preview(airPodsPro))
}

#Preview("Connected, expanded") {
    expanded(.preview(airPodsPro))
}

#Preview("AirPods Max, expanded") {
    expanded(.preview(airPodsMax))
}
#endif
