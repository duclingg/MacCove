import SwiftUI

extension Color {
    /// The iPhone's charging green, for text and the battery's fill.
    static let batteryCharging = Color(red: 137 / 255, green: 251 / 255, blue: 178 / 255)
    static let batteryLowPower = Color(red: 245 / 255, green: 201 / 255, blue: 77 / 255)
    static let batteryLow = Color(red: 1, green: 98 / 255, blue: 89 / 255)
}

extension Animation {
    /// The battery filling up when you plug in: quick start, long settle.
    static let batteryFill = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.9)
}

/// The battery's colours: yellow in Low Power Mode, which wins even while
/// charging, as on the iPhone; green while plugged in; red when low.
struct BatteryStyle {
    let tint: Color
    let fill: AnyShapeStyle
    let track: Color

    init(_ battery: BatteryMonitor) {
        if battery.isLowPowerMode {
            tint = .batteryLowPower
            fill = AnyShapeStyle(Color.batteryLowPower)
            track = Color(red: 94 / 255, green: 79 / 255, blue: 28 / 255)
        } else if battery.isPluggedIn {
            tint = .batteryCharging
            fill = AnyShapeStyle(LinearGradient(
                colors: [Color(red: 142 / 255, green: 251 / 255, blue: 155 / 255), Color(red: 144 / 255, green: 251 / 255, blue: 96 / 255)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            track = Color(red: 72 / 255, green: 105 / 255, blue: 79 / 255)
        } else if battery.level <= BatteryMonitor.lowBatteryThresholds[0] {
            tint = .batteryLow
            fill = AnyShapeStyle(Color(red: 1, green: 69 / 255, blue: 58 / 255))
            track = Color(red: 110 / 255, green: 43 / 255, blue: 39 / 255)
        } else {
            tint = .white
            fill = AnyShapeStyle(Color.white)
            track = Color(white: 0.3)
        }
    }
}

/// A solid status-bar battery: the level fills a tinted body from the left,
/// with the terminal nub beside it.
struct BatteryGlyph: View {
    /// 0 to 1.
    let level: Double
    let style: BatteryStyle
    let height: CGFloat

    var body: some View {
        let width = height * 2
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                style.track
                Rectangle()
                    .fill(style.fill)
                    .frame(width: width * min(max(level, 0), 1))
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.38, style: .continuous))
            UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2)
                .fill(style.track)
                .frame(width: 2.5, height: (height * 0.4).rounded())
        }
        .accessibilityHidden(true)
    }
}

/// "Charging" in the left wing; the percentage and a battery that fills up
/// to the current level in the right, like the iPhone's plug-in pill.
struct ChargingCompactView: View {
    let battery: BatteryMonitor
    let notchSize: CGSize

    /// Starts empty so the battery visibly fills when the pill appears.
    @State private var shownLevel = 0.0

    var body: some View {
        let layout = CompactLayout(notch: notchSize)
        let style = BatteryStyle(battery)

        HStack(spacing: 0) {
            Text("Charging")
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("\(battery.level)%")
                    .monospacedDigit()
                    .foregroundStyle(style.tint)
                BatteryGlyph(level: shownLevel, style: style, height: (notchSize.height * 0.42).rounded())
            }
        }
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, layout.sideInset + 4)
        .frame(width: NotchViewModel.chargingWidth(notch: notchSize), height: notchSize.height)
        .onAppear {
            withAnimation(.batteryFill.delay(0.12)) { shownLevel = fraction }
        }
        .onChange(of: battery.level) {
            withAnimation(.batteryFill) { shownLevel = fraction }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charging, \(battery.level) percent")
        .accessibilityAddTraits(.isButton)
    }

    private var fraction: Double {
        Double(battery.level) / 100
    }
}

/// The low battery alert: the level, and a battery button that turns Low
/// Power Mode on (or off), which then confirms it in yellow. Clicking the
/// rest of the alert opens the battery details.
struct LowBatteryAlertView: View {
    let battery: BatteryMonitor
    let notchHeight: CGFloat

    var body: some View {
        let isOn = battery.isLowPowerMode

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(battery.level)% Battery")
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                Text(isOn ? "Low Power Mode enabled" : "Click to turn on Low Power Mode")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color.batteryLowPower : .islandSecondary)
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            LowPowerModeButton(battery: battery)
        }
        .padding(.leading, 26)
        .padding(.trailing, 18)
        .padding(.top, notchHeight + NotchViewModel.alertTopGap)
        .frame(width: NotchViewModel.expandedWidth, height: notchHeight + NotchViewModel.alertBodyHeight, alignment: .top)
        .animation(.easeOut(duration: 0.3), value: isOn)
    }
}

/// A battery in a capsule. Off, it's red on dark red with a ring around the
/// level, inviting a click; on, it's black on Low Power yellow.
private struct LowPowerModeButton: View {
    let battery: BatteryMonitor

    private static let offPill = Color(red: 61 / 255, green: 23 / 255, blue: 20 / 255)
    private static let offBody = Color.batteryLow.opacity(0.42)
    private static let offLevel = Color(red: 1, green: 154 / 255, blue: 147 / 255)

    var body: some View {
        let isOn = battery.isLowPowerMode

        Button {
            battery.setLowPowerMode(!isOn)
        } label: {
            glyph(isOn: isOn)
                .frame(width: 92, height: 56)
                .background(Capsule().fill(isOn ? Color.batteryLowPower : Self.offPill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Turn off Low Power Mode" : "Turn on Low Power Mode")
    }

    private func glyph(isOn: Bool) -> some View {
        let pill = isOn ? Color.batteryLowPower : Self.offPill
        let bodyColor = isOn ? Color.black : Self.offBody
        let levelWidth = max(9, (38 * Double(battery.level) / 100).rounded())

        return HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(bodyColor)
                .frame(width: 44, height: 24)
                .overlay(alignment: .leading) {
                    ZStack {
                        // The ring sits a gap away from the level and
                        // spills just past the body's edge.
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.batteryLow, lineWidth: 2)
                            .frame(width: levelWidth + 8, height: 26)
                            .opacity(isOn ? 0 : 1)
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(pill)
                            .frame(width: levelWidth + 4, height: 22)
                            .opacity(isOn ? 0 : 1)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isOn ? Color.batteryLowPower : Self.offLevel)
                            .frame(width: levelWidth, height: 18)
                    }
                    .frame(width: levelWidth + 8, height: 26)
                    // Puts the level 3pt in from the body's left edge.
                    .offset(x: -1)
                }
            UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2)
                .fill(bodyColor)
                .frame(width: 3, height: 8)
        }
        .accessibilityHidden(true)
    }
}

/// Battery details, opened from the charging pill or the low battery alert:
/// the level, time to full or empty, the power adapter and a Low Power Mode
/// switch.
struct BatteryExpandedView: View {
    let battery: BatteryMonitor
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let barGap: CGFloat = 12
    private static let barHeight: CGFloat = 6
    private static let footerGap: CGFloat = 6
    private static let footerHeight: CGFloat = 16
    private static let switchGap: CGFloat = 12
    private static let switchHeight: CGFloat = 36
    private static let bottomGap: CGFloat = 14

    static let bodyHeight: CGFloat = NotchViewModel.expandedTopGap + headerHeight + barGap + barHeight
        + footerGap + footerHeight + switchGap + switchHeight + bottomGap

    var body: some View {
        let style = BatteryStyle(battery)

        VStack(spacing: 0) {
            header(style: style)
            levelBar(style: style)
                .padding(.top, Self.barGap)
            footer
                .padding(.top, Self.footerGap)
            lowPowerSwitch
                .padding(.top, Self.switchGap)
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
        .animation(.easeOut(duration: 0.3), value: battery.isLowPowerMode)
    }

    private func header(style: BatteryStyle) -> some View {
        HStack(spacing: 12) {
            Image(systemName: battery.isPluggedIn ? "bolt.fill" : symbolName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(style.tint)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(battery.level)%")
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(style.tint)
        }
        .frame(height: Self.headerHeight)
        .accessibilityElement(children: .combine)
    }

    private func levelBar(style: BatteryStyle) -> some View {
        Capsule()
            .fill(.white.opacity(0.18))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(style.fill)
                        .frame(width: proxy.size.width * CGFloat(battery.level) / 100)
                }
            }
            .frame(height: Self.barHeight)
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack {
            Text(powerSource)
            Spacer()
            if let fullAt {
                Text(fullAt)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.islandSecondary)
        .frame(height: Self.footerHeight)
    }

    private var lowPowerSwitch: some View {
        HStack {
            Text("Low Power Mode")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Toggle("Low Power Mode", isOn: Binding(
                get: { battery.isLowPowerMode },
                set: { battery.setLowPowerMode($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.green)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.switchHeight)
        .background(RoundedRectangle(cornerRadius: Self.switchHeight / 2, style: .continuous).fill(.white.opacity(0.12)))
    }

    private var title: String {
        if battery.isPluggedIn {
            if battery.level >= 100 { return "Fully Charged" }
            return battery.isCharging ? "Charging" : "Not Charging"
        }
        if battery.isLowPowerMode { return "Low Power Mode" }
        return battery.level <= BatteryMonitor.lowBatteryThresholds[0] ? "Low Battery" : "Battery"
    }

    private var subtitle: String {
        if battery.isPluggedIn {
            if battery.level >= 100 { return "Connected to power" }
            guard battery.isCharging else { return "Paused to protect the battery" }
            return battery.minutesToFull.map { "\(Self.duration($0)) until full" } ?? "Estimating time until full"
        }
        return battery.minutesToEmpty.map { "About \(Self.duration($0)) remaining" } ?? "Estimating time remaining"
    }

    private var powerSource: String {
        guard battery.isPluggedIn else { return "On battery" }
        return battery.adapterWatts.map { "\($0) W power adapter" } ?? "Power adapter"
    }

    private var fullAt: String? {
        guard battery.isPluggedIn, battery.isCharging, let minutes = battery.minutesToFull else { return nil }
        let time = Date.now.addingTimeInterval(TimeInterval(minutes * 60)).formatted(date: .omitted, time: .shortened)
        return "Full at \(time)"
    }

    /// The closest of the battery symbols' five fill levels.
    private var symbolName: String {
        let step = min(4, max(0, Int((Double(battery.level) / 25).rounded())))
        return "battery.\(step * 25)percent"
    }

    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }
}
