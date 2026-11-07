//
//  SignInViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import SwiftUI

extension Color {
    /// The system green on dark, for the open lock and the check.
    static let signInUnlocked = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
}

extension Animation {
    /// The check and the open lock arriving: quick, with a little bounce.
    static let unlock = Animation.spring(duration: 0.4, bounce: 0.35)
}

/// What the pill draws. A beat behind the monitor when Touch ID unlocks,
/// so the fingerprint can fill in before the check takes over; the lock
/// opens straight away.
enum SignInDisplay: Equatable {
    case touchID
    /// Unlocked: the ridges filling in.
    case filling
    case unlocked

    /// Unlocked, or filling in on the way there.
    var isUnlocked: Bool {
        self == .filling || self == .unlocked
    }
}

/// Follows the monitor into a `SignInDisplay`. Once the prompt is gone the
/// last look stays, for the island to fade out.
private struct SignInSequence: ViewModifier {
    let prompt: SignInMonitor.Prompt?
    @Binding var display: SignInDisplay

    func body(content: Content) -> some View {
        content
            .onChange(of: prompt, initial: true) {
                switch prompt {
                case .touchID?:
                    display = .touchID
                case .unlocked?:
                    if display == .touchID {
                        withAnimation(.unlock) { display = .filling }
                    }
                case nil:
                    break
                }
            }
            .task(id: display) {
                guard display == .filling else { return }
                do {
                    try await Task.sleep(for: TouchIDGlyph.fillDuration)
                } catch {
                    return
                }
                withAnimation(.unlock) { display = .unlocked }
            }
    }
}

/// The Touch ID fingerprint. It waits unfilled; once the finger is read,
/// its ridges fill in patch by patch, the way Touch ID setup shows how much
/// of the finger it has, then it shrinks away as a check draws in.
///
/// Played from one clock rather than chained animations, so each step
/// carries on from exactly where the last one left off.
struct TouchIDGlyph: View {
    let size: CGFloat
    let display: SignInDisplay

    private static let fillSeconds = 0.35
    /// How long the ridges take to fill, after which the check takes over.
    static let fillDuration: Duration = .seconds(fillSeconds)

    @State private var unlockStart: Date?

    var body: some View {
        TimelineView(.animation(paused: unlockStart == nil)) { context in
            let look = Look(elapsed: unlockStart.map { context.date.timeIntervalSince($0) })
            ZStack {
                ZStack {
                    symbol
                        .foregroundStyle(.white.opacity(0.28))
                    symbol
                        .foregroundStyle(look.isGreen ? Color.signInUnlocked : .white)
                        // Bigger than the glyph, so the soft edges of the
                        // patches fall outside it once it's all filled.
                        .mask {
                            CoverageMask(coverage: look.coverage, softness: size * 0.06)
                                .frame(width: size * 1.3, height: size * 1.3)
                        }
                }
                .opacity(look.printOpacity)
                .scaleEffect(look.printScale)

                Checkmark()
                    .trim(from: 0, to: look.check)
                    .stroke(Color.signInUnlocked, style: StrokeStyle(lineWidth: size * 2.8 / 24, lineCap: .round, lineJoin: .round))
                    .scaleEffect(look.checkScale)
            }
            .animation(.easeOut(duration: 0.15), value: look.isGreen)
        }
        .frame(width: size, height: size)
        .onChange(of: display, initial: true) {
            if display == .touchID {
                unlockStart = nil
            } else if unlockStart == nil {
                unlockStart = .now
            }
        }
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: "touchid")
            .resizable()
            .scaledToFit()
    }

    /// Everything that moves, worked out from the time since unlocking.
    private struct Look {
        var coverage = 0.0
        var isGreen = false
        var printOpacity = 1.0
        var printScale = 1.0
        var check = 0.0
        var checkScale = 0.8

        init(elapsed: TimeInterval?) {
            guard let elapsed else { return }
            let fill = TouchIDGlyph.fillSeconds
            coverage = Self.easeOut(Self.progress(elapsed, from: 0, over: fill))
            // Green as the last patches go in, then it shrinks away under the
            // check, which starts drawing just before it's full.
            isGreen = elapsed >= fill * 0.6
            let away = Self.easeIn(Self.progress(elapsed, from: fill - 0.05, over: 0.2))
            printOpacity = 1 - away
            printScale = 1 - 0.25 * away
            let drawing = Self.progress(elapsed, from: fill - 0.08, over: 0.28)
            check = Self.easeOut(drawing)
            checkScale = 0.8 + 0.2 * Self.easeOutBack(drawing)
        }

        private static func progress(_ time: TimeInterval, from start: TimeInterval, over duration: TimeInterval) -> Double {
            min(max((time - start) / duration, 0), 1)
        }

        private static func easeIn(_ x: Double) -> Double { x * x }
        private static func easeOut(_ x: Double) -> Double { 1 - (1 - x) * (1 - x) }
        /// Overshoots a little before settling, like a spring.
        private static func easeOutBack(_ x: Double) -> Double {
            let overshoot = 1.7
            return 1 + (overshoot + 1) * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
        }
    }
}

/// Patches around the fingerprint's centre that light up in a scattered
/// order as `coverage` goes from 0 to 1, a little more often near the
/// middle first, as a finger reads. Blurred so neighbours run together.
private struct CoverageMask: View {
    let coverage: Double
    let softness: CGFloat

    private struct Patch: Sendable {
        var inner: Double
        var outer: Double
        var from: Angle
        var to: Angle
        /// The coverage at which it starts to light up.
        var start: Double
    }

    private static let rings = 4
    private static let sectors = 8
    /// The share of the fill each patch takes to light up fully.
    private static let fade = 0.22

    private static let patches: [Patch] = {
        var patches: [Patch] = []
        var seed: UInt32 = 7
        for ring in 0..<rings {
            for sector in 0..<sectors {
                // A fixed scatter, so it fills the same way every time.
                seed = seed &* 1_103_515_245 &+ 12345
                let scatter = Double(seed >> 16 & 0x7FFF) / Double(0x7FFF)
                let fromCentre = Double(ring) / Double(rings - 1)
                let sectorAngle = 360.0 / Double(sectors)
                patches.append(Patch(
                    inner: Double(ring) / Double(rings),
                    outer: Double(ring + 1) / Double(rings),
                    // Overlapping a little, so no seams show between them.
                    from: .degrees(Double(sector) * sectorAngle - 3),
                    to: .degrees(Double(sector + 1) * sectorAngle + 3),
                    start: (0.45 * fromCentre + 0.55 * scatter) * (1 - fade)
                ))
            }
        }
        return patches
    }()

    var body: some View {
        let patches = Self.patches
        let fade = Self.fade
        let coverage = coverage

        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = hypot(size.width, size.height) / 2
            for patch in patches {
                let opacity = min(max((coverage - patch.start) / fade, 0), 1)
                guard opacity > 0 else { continue }
                var path = Path()
                path.addArc(center: centre, radius: radius * patch.outer, startAngle: patch.from, endAngle: patch.to, clockwise: false)
                path.addArc(center: centre, radius: radius * patch.inner, startAngle: patch.to, endAngle: patch.from, clockwise: true)
                path.closeSubpath()
                context.fill(path, with: .color(.white.opacity(opacity)))
            }
        }
        .blur(radius: softness)
    }
}

/// The check from the design, in a 24pt box, for drawing on with `trim`.
nonisolated private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        path.move(to: point(5, 12.5))
        path.addLine(to: point(9.5, 17))
        path.addLine(to: point(19, 7))
        return path
    }
}

/// The lock beside the notch, springing open in green once unlocked.
private struct SignInLock: View {
    let isUnlocked: Bool

    var body: some View {
        Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isUnlocked ? Color.signInUnlocked : .white)
            // Morphs the shackle open rather than swapping the symbol.
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp.byLayer)))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// A lock in the left wing and, in the right, the fingerprint, which fills
/// in and gives way to a check once unlocked.
struct SignInCompactView: View {
    let signIn: SignInMonitor
    let notchSize: CGSize

    @State private var display = SignInDisplay.touchID

    var body: some View {
        let layout = CompactLayout(notch: notchSize)

        HStack(spacing: 0) {
            SignInLock(isUnlocked: display.isUnlocked)
            Spacer(minLength: 0)
            TouchIDGlyph(size: 21, display: display)
        }
        .padding(.horizontal, layout.sideInset)
        .frame(width: NotchViewModel.signInWidth(notch: notchSize), height: notchSize.height)
        .modifier(SignInSequence(prompt: signIn.prompt, display: $display))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(display))
    }

    private static func accessibilityLabel(_ display: SignInDisplay) -> String {
        switch display {
        case .touchID: "Waiting for Touch ID"
        case .filling, .unlocked: "Unlocked"
        }
    }
}
