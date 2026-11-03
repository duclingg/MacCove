import SwiftUI

extension Color {
    /// The system green on dark, for the open lock and the check.
    static let signInUnlocked = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
}

extension Animation {
    /// The check and the open lock arriving: quick, with a little bounce.
    static let unlock = Animation.spring(duration: 0.4, bounce: 0.35)
}

/// What the prompt views draw. A beat behind the monitor when Touch ID
/// unlocks, so the fingerprint can fill in before the label changes; the
/// lock opens straight away.
enum SignInDisplay: Equatable {
    case touchID
    /// Unlocked with Touch ID: the ridges filling in.
    case filling
    case password(length: Int)
    case unlocked

    /// Unlocked, or filling in on the way there.
    var isUnlocked: Bool {
        self == .filling || self == .unlocked
    }
}

/// Follows the monitor into a `SignInDisplay`. After a password there's no
/// fingerprint to fill, so the check comes straight away. Once the prompt
/// is gone the last look stays, for the island to fade out.
private struct SignInSequence: ViewModifier {
    let prompt: SignInMonitor.Prompt?
    @Binding var display: SignInDisplay

    func body(content: Content) -> some View {
        content
            .onChange(of: prompt, initial: true) {
                switch prompt {
                case .touchID?:
                    display = .touchID
                case .password(let length)?:
                    display = .password(length: length)
                case .unlocked?:
                    if case .password = display {
                        withAnimation(.unlock) { display = .unlocked }
                    } else if display != .unlocked {
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
/// of the finger it has, then it shrinks away, for a check that draws in
/// or for whatever its parent puts in its place. Arriving already unlocked,
/// after the password, it only draws the check.
///
/// Played from one clock rather than chained animations, so each step
/// carries on from exactly where the last one left off.
struct TouchIDGlyph: View {
    let size: CGFloat
    /// `.touchID`, `.filling` or `.unlocked`.
    let display: SignInDisplay
    var drawsCheck = true

    private static let fillSeconds = 0.35
    /// How long the ridges take to fill, after which the check takes over.
    static let fillDuration: Duration = .seconds(fillSeconds)

    @State private var unlockStart: Date?
    @State private var skipsFill = false

    var body: some View {
        TimelineView(.animation(paused: unlockStart == nil)) { context in
            let look = Look(
                elapsed: unlockStart.map { context.date.timeIntervalSince($0) },
                skipsFill: skipsFill,
                drawsCheck: drawsCheck
            )
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
            switch display {
            case .filling:
                if unlockStart == nil {
                    unlockStart = .now
                }
            case .unlocked:
                if unlockStart == nil {
                    skipsFill = true
                    unlockStart = .now
                }
            default:
                unlockStart = nil
                skipsFill = false
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

        init(elapsed: TimeInterval?, skipsFill: Bool, drawsCheck: Bool) {
            guard let elapsed else { return }
            let fill = TouchIDGlyph.fillSeconds
            if skipsFill {
                printOpacity = 0
            } else {
                coverage = Self.easeOut(Self.progress(elapsed, from: 0, over: fill))
                // Green as the last patches go in, then it shrinks away under
                // the check, which starts drawing just before it's full.
                isGreen = elapsed >= fill * 0.6
                let away = Self.easeIn(Self.progress(elapsed, from: fill - 0.05, over: 0.2))
                printOpacity = 1 - away
                printScale = 1 - 0.25 * away
            }
            guard drawsCheck else { return }
            let drawing = Self.progress(elapsed, from: skipsFill ? 0 : fill - 0.08, over: 0.28)
            check = Self.easeOut(drawing)
            checkScale = 0.8 + 0.2 * Self.easeOutBack(drawing)
        }

        private static func progress(_ time: TimeInterval, from start: TimeInterval, over duration: TimeInterval) -> Double {
            min(max((time - start) / duration, 0), 1)
        }

        private static func easeIn(_ x: Double) -> Double { x * x }
        private static func easeOut(_ x: Double) -> Double { 1 - (1 - x) * (1 - x) }
        private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
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

/// The macOS login window's head shake for a wrong password.
private struct RejectionShake: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-10, duration: 0.05)
                LinearKeyframe(9, duration: 0.08)
                LinearKeyframe(-7, duration: 0.08)
                LinearKeyframe(5, duration: 0.07)
                LinearKeyframe(-2, duration: 0.06)
                SpringKeyframe(0, duration: 0.2, spring: .snappy)
            }
        }
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

/// A big lock that arrives shut, in white, and springs open in green a
/// moment later.
private struct OpeningLock: View {
    let size: CGFloat

    /// Long enough to see it shut before it opens.
    private static let openDelay: Duration = .milliseconds(120)

    @State private var isOpen = false

    var body: some View {
        Image(systemName: isOpen ? "lock.open.fill" : "lock.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(isOpen ? Color.signInUnlocked : .white)
            // Morphs the shackle open rather than swapping the symbol.
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp.byLayer)))
            .task {
                do {
                    try await Task.sleep(for: Self.openDelay)
                } catch {
                    return
                }
                withAnimation(.unlock) { isOpen = true }
            }
            .accessibilityHidden(true)
    }
}

/// A lock in the left wing and, in the right, the fingerprint, a dot for
/// each character of the password, or a check once unlocked.
struct SignInCompactView: View {
    let signIn: SignInMonitor
    let notchSize: CGSize

    @State private var display = SignInDisplay.touchID

    var body: some View {
        let layout = CompactLayout(notch: notchSize)

        HStack(spacing: 0) {
            SignInLock(isUnlocked: display.isUnlocked)
            Spacer(minLength: 0)
            trail
                .modifier(RejectionShake(trigger: signIn.rejections))
        }
        .padding(.horizontal, layout.sideInset + 4)
        .frame(width: NotchViewModel.signInWidth(notch: notchSize, prompt: signIn.prompt), height: notchSize.height)
        .modifier(SignInSequence(prompt: signIn.prompt, display: $display))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(display))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trail: some View {
        switch display {
        // One case, so the fingerprint is the same view all the way to the
        // check.
        case .touchID, .filling, .unlocked:
            TouchIDGlyph(size: 21, display: display)
        case .password(let length) where length == 0:
            Text("Password")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
        case .password(let length):
            HStack(spacing: 4) {
                // As many as fit in the wing; the expanded view counts on.
                ForEach(0..<min(length, 6), id: \.self) { _ in
                    Circle()
                        .frame(width: 6, height: 6)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.25, bounce: 0.4), value: length)
        }
    }

    static func accessibilityLabel(_ display: SignInDisplay) -> String {
        switch display {
        case .touchID: "Waiting for Touch ID"
        case .password(let length): "Password, \(length) characters typed"
        case .filling, .unlocked: "Unlocked"
        }
    }
}

/// The square the prompt opens into, as on the iPhone: a big fingerprint,
/// or the keyboard with a row of dots filling as the password is typed,
/// and once unlocked, a lock that springs open.
struct SignInExpandedView: View {
    let signIn: SignInMonitor
    let notchHeight: CGFloat

    static let width: CGFloat = 220
    /// Under the notch: the 64pt glyph, its label and the dots.
    static let bodyHeight: CGFloat = 150
    static let cornerRadius: CGFloat = 36

    private static let glyphSize: CGFloat = 64
    private static let dotCount = 8

    @State private var display = SignInDisplay.touchID

    var body: some View {
        VStack(spacing: 10) {
            glyph
                .frame(width: Self.glyphSize, height: Self.glyphSize)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.opacity)
            if case .password(let length) = display {
                dots(typed: length)
                    .modifier(RejectionShake(trigger: signIn.rejections))
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width, height: Self.bodyHeight)
        .padding(.top, notchHeight)
        .frame(width: Self.width, height: notchHeight + Self.bodyHeight, alignment: .top)
        .animation(.easeOut(duration: 0.25), value: label)
        .modifier(SignInSequence(prompt: signIn.prompt, display: $display))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SignInCompactView.accessibilityLabel(display))
    }

    @ViewBuilder
    private var glyph: some View {
        switch display {
        // One case, so the fingerprint fills in and shrinks away as the
        // lock takes its place, rather than being swapped out.
        case .touchID, .filling, .unlocked:
            ZStack {
                TouchIDGlyph(size: Self.glyphSize, display: display, drawsCheck: false)
                if display == .unlocked {
                    OpeningLock(size: 44)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        case .password:
            Image(systemName: "keyboard")
                .font(.system(size: 44, weight: .light))
                .transition(.opacity)
        }
    }

    private func dots(typed: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.dotCount, id: \.self) { index in
                let isTyped = index < typed
                Circle()
                    .fill(.white.opacity(isTyped ? 1 : 0.22))
                    .frame(width: 8, height: 8)
                    .scaleEffect(isTyped ? 1 : 0.85)
            }
        }
        .frame(height: 8)
        .animation(.spring(duration: 0.2, bounce: 0.5), value: typed)
    }

    private var label: String {
        switch display {
        case .touchID, .filling: "Touch ID"
        case .password: "Password"
        case .unlocked: "Unlocked"
        }
    }
}
