//
//  SignInPreviews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

#if DEBUG
import SwiftUI

private let notch = CGSize(width: 186, height: 37)

private func compact(_ signIn: SignInMonitor) -> some View {
    IslandPreview(
        size: CGSize(width: NotchViewModel.signInWidth(notch: notch), height: notch.height),
        cornerRadius: NotchViewModel.compactCornerRadius
    ) {
        SignInCompactView(signIn: signIn, notchSize: notch)
    }
}

#Preview("Touch ID → Unlocked (loops)") {
    compact(.demo())
}

#Preview("Waiting for Touch ID") {
    compact(.preview(.touchID))
}

#Preview("Unlocked") {
    compact(.preview(.unlocked))
}
#endif
