//
//  IslandPreview.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

#if DEBUG
import SwiftUI

/// Island content drawn the way the island draws it: black, hanging from
/// the top edge with rounded bottom corners, at the size `NotchViewModel`
/// gives it on a 186 by 37pt notch, over a plain desktop.
struct IslandPreview<Content: View>: View {
    let size: CGSize
    let cornerRadius: CGFloat
    var isLifted = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))
            .shadow(color: .black.opacity(isLifted ? 0.42 : 0), radius: 24, y: 18)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .frame(width: 520, height: size.height + 60, alignment: .top)
            .background(LinearGradient(
                colors: [Color(red: 0.22, green: 0.42, blue: 0.76), Color(red: 0.13, green: 0.27, blue: 0.55)],
                startPoint: .top,
                endPoint: .bottom
            ))
    }
}
#endif
