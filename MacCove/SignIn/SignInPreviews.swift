#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

/// Follows the prompt's width, so the demos widen for the dots as the
/// island does.
private struct Compact: View {
    let signIn: SignInMonitor

    var body: some View {
        IslandPreview(
            size: CGSize(width: NotchViewModel.signInWidth(notch: notch, prompt: signIn.prompt), height: notch.height),
            cornerRadius: NotchViewModel.compactCornerRadius
        ) {
            SignInCompactView(signIn: signIn, notchSize: notch)
        }
        .animation(.island, value: signIn.prompt)
    }
}

private func expanded(_ signIn: SignInMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: SignInExpandedView.width, height: notch.height + SignInExpandedView.bodyHeight),
        cornerRadius: SignInExpandedView.cornerRadius,
        isLifted: true
    ) {
        SignInExpandedView(signIn: signIn, notchHeight: notch.height)
    }
}

// MARK: - Played through (loops)

#Preview("Touch ID → Unlocked") {
    Compact(signIn: .demo(typingPassword: false))
}

#Preview("Touch ID → Unlocked, Expanded") {
    expanded(.demo(typingPassword: false))
}

#Preview("Password · Wrong, Then Right") {
    Compact(signIn: .demo(typingPassword: true))
}

#Preview("Password · Wrong, Then Right, Expanded") {
    expanded(.demo(typingPassword: true))
}

// MARK: - Each state

#Preview("Waiting for Touch ID") {
    Compact(signIn: .preview(.touchID))
}

#Preview("Waiting for Touch ID, Expanded") {
    expanded(.preview(.touchID))
}

#Preview("Typing the Password") {
    Compact(signIn: .preview(.password(length: 6)))
}

#Preview("Typing the Password, Expanded") {
    expanded(.preview(.password(length: 6)))
}

#Preview("Unlocked") {
    Compact(signIn: .preview(.unlocked))
}

#Preview("Unlocked, Expanded") {
    expanded(.preview(.unlocked))
}
#endif
