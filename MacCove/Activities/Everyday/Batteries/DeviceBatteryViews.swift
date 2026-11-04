//
//  DeviceBatteryViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI

extension BatteryStyle {
    init(tint: Color, fill: AnyShapeStyle, track: Color) {
        self.tint = tint
        self.fill = fill
        self.track = track
    }

    /// Green while it charges, red when it's low, white otherwise.
    static func device(_ device: PeripheralDevice) -> BatteryStyle {
        if device.isCharging {
            return BatteryStyle(
                tint: .batteryCharging,
                fill: AnyShapeStyle(Color.batteryCharging),
                track: Color(red: 72 / 255, green: 105 / 255, blue: 79 / 255)
            )
        }
        if DeviceBatteryMonitor.isLow(device) {
            return BatteryStyle(
                tint: .batteryLow,
                fill: AnyShapeStyle(Color(red: 1, green: 69 / 255, blue: 58 / 255)),
                track: Color(red: 110 / 255, green: 43 / 255, blue: 39 / 255)
            )
        }
        return BatteryStyle(tint: .white, fill: AnyShapeStyle(Color.white), track: .white.opacity(0.25))
    }
}

private struct DeviceGlyph: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (size * 0.72).rounded(), weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "Magic Mouse, 10 percent, low".
private func spokenLevel(_ device: PeripheralDevice) -> String {
    var parts = [device.name, "\(device.level) percent"]
    if device.isCharging {
        parts.append("charging")
    } else if DeviceBatteryMonitor.isLow(device) {
        parts.append("low")
    }
    return parts.joined(separator: ", ")
}

/// The device in the left wing, red when it's low and green while it
/// charges. In the right, its level and battery, or how many devices
/// there are while they're all listed.
struct DeviceBatteryCompactView: View {
    let batteries: DeviceBatteryMonitor
    let notchSize: CGSize

    private static let trailingFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    private static let levelGap: CGFloat = 6
    /// Between the text and the notch, as the artwork has.
    private static let notchGap: CGFloat = 12

    static func glyphHeight(notch: CGSize) -> CGFloat {
        (notch.height * 0.4).rounded()
    }

    /// Wide enough for 100% and the battery, the same on both sides so the
    /// notch stays in the middle, and the same whatever the level.
    static func width(for batteries: DeviceBatteryMonitor, notch: CGSize) -> CGFloat {
        let layout = CompactLayout(notch: notch)
        let trailing: CGFloat
        if batteries.featured != nil {
            let height = glyphHeight(notch: notch)
            // As BatteryGlyph draws it: the body, a gap and the nub.
            let glyph = height * 2 + 1.5 + 2.5
            trailing = textWidth("100%") + levelGap + glyph
        } else {
            trailing = textWidth("88")
        }
        return notch.width + (layout.sideInset + max(layout.artSize, trailing) + notchGap) * 2
    }

    private static func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: trailingFont]).width.rounded(.up)
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let device = batteries.featured

        HStack(spacing: 0) {
            DeviceGlyph(
                symbol: device?.systemImage ?? batteries.allDevices.first?.systemImage ?? "computermouse.fill",
                color: device.map { BatteryStyle.device($0).tint } ?? .white,
                size: layout.artSize
            )
            Spacer(minLength: 0)
            if let device {
                let style = BatteryStyle.device(device)
                HStack(spacing: Self.levelGap) {
                    Text("\(device.level)%")
                        .foregroundStyle(style.tint)
                    BatteryGlyph(level: Double(device.level) / 100, style: style, height: Self.glyphHeight(notch: notchSize))
                }
            } else {
                Text("\(batteries.allDevices.count)")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, layout.sideInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .frame(width: Self.width(for: batteries, notch: notchSize), height: notchSize.height)
    }

    private var accessibilityDescription: String {
        switch batteries.phase {
        case .low?, .connected?, .charging?:
            guard let device = batteries.featured else { return "Device batteries" }
            return spokenLevel(device)
        case .list?:
            let count = batteries.allDevices.count
            return count == 1 ? "1 device connected" : "\(count) devices connected"
        case nil:
            return "Device batteries"
        }
    }
}

/// The device in a bubble beside another activity, in its battery's
/// colour.
struct DeviceBatteryMinimalView: View {
    let batteries: DeviceBatteryMonitor
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)
        let device = batteries.featured

        DeviceGlyph(
            symbol: device?.systemImage ?? batteries.allDevices.first?.systemImage ?? "computermouse.fill",
            color: device.map { BatteryStyle.device($0).tint } ?? .white,
            size: layout.artSize
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.map(spokenLevel) ?? "Device batteries")
        .accessibilityAddTraits(.isButton)
    }
}

/// Opened up. A low device with Dismiss and Remind Me Tonight; otherwise
/// every connected device and its level.
struct DeviceBatteryExpandedView: View {
    let batteries: DeviceBatteryMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let chipsGap: CGFloat = 12
    private static let chipHeight: CGFloat = 36
    private static let listGap: CGFloat = 10
    private static let listPadding: CGFloat = 4
    private static let rowHeight: CGFloat = 40
    /// The list, as far as this; the header counts them all.
    private static let maxRows = 5
    private static let bottomGap: CGFloat = 14

    static func bodyHeight(for batteries: DeviceBatteryMonitor) -> CGFloat {
        var height = NotchViewModel.expandedTopGap + headerHeight + bottomGap
        switch batteries.phase {
        case .low?:
            height += chipsGap + chipHeight
        case .connected?, .charging?, .list?:
            let rows = min(batteries.allDevices.count, maxRows)
            if rows > 0 {
                height += listGap + listPadding * 2 + rowHeight * CGFloat(rows)
            }
        case nil:
            break
        }
        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            switch batteries.phase {
            case .low?:
                if let device = batteries.featured {
                    low(device)
                }
            case .connected?, .charging?, .list?:
                list
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private func header(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
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

    // MARK: - Low

    @ViewBuilder
    private func low(_ device: PeripheralDevice) -> some View {
        header(
            symbol: device.systemImage,
            tint: .batteryLow,
            title: "\(device.name) is low",
            subtitle: "\(device.level)% · plug it in soon"
        )
        HStack(spacing: 8) {
            chip("Dismiss") { batteries.dismiss() }
            chip(DeviceBatteryMonitor.remindsTonight() ? "Remind Me Tonight" : "Remind Me in 1 Hour") {
                batteries.remindLater()
            }
        }
        .padding(.top, Self.chipsGap)
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Every device

    @ViewBuilder
    private var list: some View {
        let devices = batteries.allDevices
        header(
            symbol: batteries.featured?.systemImage ?? devices.first?.systemImage ?? "computermouse.fill",
            tint: .white,
            title: "Devices",
            subtitle: devices.isEmpty ? "None connected" : "\(devices.count) connected"
        )
        if !devices.isEmpty {
            VStack(spacing: 0) {
                ForEach(devices.prefix(Self.maxRows)) { device in
                    row(device)
                }
            }
            .padding(.vertical, Self.listPadding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            .padding(.top, Self.listGap)
        }
    }

    /// What it is, its battery, and its level, red when it's low.
    private func row(_ device: PeripheralDevice) -> some View {
        let style = BatteryStyle.device(device)
        let isLow = DeviceBatteryMonitor.isLow(device)

        return HStack(spacing: 10) {
            Image(systemName: device.systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.1)))
            Text(device.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            BatteryGlyph(level: Double(device.level) / 100, style: style, height: 11)
            Text("\(device.level)%")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(device.isCharging ? Color.batteryCharging : isLow ? Color.batteryLow : Color.islandSecondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLevel(device))
    }
}
