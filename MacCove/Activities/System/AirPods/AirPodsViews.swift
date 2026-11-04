//
//  AirPodsViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI

/// The ring's colour: green, as the iPhone has it, or red once a bud is
/// nearly flat.
private func ringColor(_ level: Int) -> Color {
    level <= DeviceBatteryMonitor.lowThresholds[0] ? .batteryLow : .batteryCharging
}

/// The headphones, turning round twice as they appear, as the iPhone's do
/// when AirPods connect.
private struct SpinningGlyph: View {
    let symbol: String
    let size: CGFloat
    var spins = true

    @State private var angle = 0.0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (size * 0.78).rounded(), weight: .medium))
            .frame(width: size, height: size)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .accessibilityHidden(true)
            .onAppear {
                guard spins else { return }
                withAnimation(.timingCurve(0.25, 0.7, 0.3, 1, duration: 1.4).delay(0.3)) {
                    angle = 720
                }
            }
    }
}

/// The level as a ring over a dim track.
private struct LevelRing: View {
    let level: Int
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(level) / 100)
                .stroke(ringColor(level), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: level)
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The AirPods in the left wing, turning round as they connect; their
/// battery as a ring in the right, once they've said what it is.
struct AirPodsCompactView: View {
    let airPods: AirPodsMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let headphones = airPods.shown

        HStack(spacing: 0) {
            SpinningGlyph(symbol: headphones?.systemImage ?? "airpods", size: layout.artSize)
            Spacer(minLength: 0)
            if let level = headphones?.battery.level {
                LevelRing(level: level, diameter: layout.artSize, lineWidth: 3)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, layout.sideInset)
        .animation(.easeOut(duration: 0.2), value: headphones?.battery.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
    }

    private var accessibilityDescription: String {
        guard let headphones = airPods.shown else { return "AirPods" }
        guard let level = headphones.battery.level else { return "\(headphones.title) connected" }
        return "\(headphones.title) connected, \(level) percent battery"
    }
}

/// The AirPods in a bubble beside another activity.
struct AirPodsMinimalView: View {
    let airPods: AirPodsMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)

        SpinningGlyph(symbol: airPods.shown?.systemImage ?? "airpods", size: layout.artSize, spins: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(airPods.shown.map { "\($0.title) connected" } ?? "AirPods")
            .accessibilityAddTraits(.isButton)
    }
}

/// Opened up: which headphones, and each bud's level and the case's, or
/// the one level headphones like AirPods Max have.
struct AirPodsExpandedView: View {
    let airPods: AirPodsMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    static func bodyHeight(for airPods: AirPodsMonitor) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        if let headphones = airPods.shown, !levels(headphones.battery).isEmpty {
            height += chipsGap + chipHeight
        }
        return height
    }

    /// Left, Right and Case, each only when it's known.
    private static func levels(_ battery: HeadphonesBattery) -> [(label: String, level: Int)] {
        if battery.left == nil, battery.right == nil, let single = battery.single {
            return [(label: "Battery", level: single)]
        }
        let parts: [(String, Int?)] = [("Left", battery.left), ("Right", battery.right), ("Case", battery.caseLevel)]
        return parts.compactMap { part in part.1.map { (label: part.0, level: $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let headphones = airPods.shown {
                header(headphones)
                let levels = Self.levels(headphones.battery)
                if !levels.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(levels.indices, id: \.self) { index in
                            chip(levels[index].label, level: levels[index].level)
                        }
                    }
                    .padding(.top, Self.chipsGap)
                }
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private func header(_ headphones: ConnectedHeadphones) -> some View {
        HStack(spacing: 12) {
            Image(systemName: headphones.systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(headphones.title)
                    .font(.system(size: 15, weight: .semibold))
                Text("Connected")
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .frame(height: Self.headerHeight)
    }

    /// Not a button: just what's in it, "Left 88%".
    private func chip(_ label: String, level: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.islandSecondary)
            Text("\(level)%")
                .monospacedDigit()
                .foregroundStyle(level <= DeviceBatteryMonitor.lowThresholds[0] ? Color.batteryLow : .white)
        }
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity)
        .frame(height: Self.chipHeight)
        .background(Capsule().fill(.white.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}
