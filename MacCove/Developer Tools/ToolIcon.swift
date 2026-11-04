//
//  ToolIcon.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI

/// A developer tool's icon, from its image in the asset catalog.
///
/// Every icon comes out the same size, on macOS's app icon grid: a body
/// 824 of 1024 points across with 22.5% corners, centred in the frame.
/// The images differ in how much of their canvas they fill, so each is
/// scaled by what it was measured to fill, and bare logos are put on a
/// tile in their brand's colours with their outline the same share of it.
struct ToolIcon: View {
    enum Tool: String, CaseIterable {
        case claudeCode = "ClaudeCode"
        case codex = "Codex"
        case cursor = "Cursor"
        case gitHub = "Github"
        case terminal = "Terminal"
        case vsCode = "VSCode"
        case xcode = "Xcode"

        fileprivate enum Style {
            /// A finished macOS app icon, with its own shape.
            case appIcon
            /// A square image filled to its edges, given app-icon corners.
            case square
            /// A bare logo, put on a tile in its brand's colours: the light
            /// version on dark rows and the dark one on light rows. A tile
            /// the same shade as its row loses its edge and looks smaller.
            case logo(light: Palette, dark: Palette)
        }

        fileprivate struct Palette {
            let tile: Color
            let mark: Color
        }

        /// The colours are each brand's own, in both versions it publishes:
        /// Cursor's from its brand kit, Codex's from OpenAI's icons, and
        /// GitHub's from its brand toolkit, which keeps the Invertocat to
        /// black or white.
        fileprivate var style: Style {
            switch self {
            case .terminal, .vsCode, .xcode: .appIcon
            case .claudeCode: .square
            case .codex:
                .logo(light: Palette(tile: .white, mark: .black), dark: Palette(tile: .black, mark: .white))
            case .cursor:
                .logo(
                    light: Palette(tile: Color(hex: 0xF0EFEA), mark: Color(hex: 0x14120B)),
                    dark: Palette(tile: Color(hex: 0x14120B), mark: Color(hex: 0xEDECEC))
                )
            case .gitHub:
                .logo(light: Palette(tile: .white, mark: .black), dark: Palette(tile: .black, mark: .white))
            }
        }

        /// How much of its image's width or height an app icon's shape
        /// fills, whichever is more, as measured from the asset's opaque
        /// pixels. Update it when an image is replaced.
        fileprivate var artworkShare: CGFloat {
            switch self {
            case .terminal: 0.817
            case .vsCode: 0.814
            case .xcode: 0.906
            case .claudeCode, .codex, .cursor, .gitHub: 1
            }
        }

        /// How much of its image a logo's outline covers, filled in, as
        /// measured from the asset. Logos are sized by this rather than by
        /// their box, so Cursor's pointed hexagon doesn't look smaller than
        /// GitHub's circle. Update it when an image is replaced.
        fileprivate var outlineArea: CGFloat {
            switch self {
            case .codex: 0.648
            case .cursor: 0.668
            case .gitHub: 0.783
            case .claudeCode, .terminal, .vsCode, .xcode: 1
            }
        }
    }

    /// An app icon's body, on macOS's 1024-point grid.
    private static let bodyShare: CGFloat = 824 / 1024
    private static let cornerShare: CGFloat = 0.225
    /// What a logo's outline covers of its tile: as much as a circle 60%
    /// of the tile across.
    private static let logoArea: CGFloat = .pi / 4 * 0.6 * 0.6

    let tool: Tool
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(_ tool: Tool, size: CGFloat = 25) {
        self.tool = tool
        self.size = size
    }

    var body: some View {
        icon
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var bodySize: CGFloat {
        size * Self.bodyShare
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: bodySize * Self.cornerShare, style: .continuous)
    }

    @ViewBuilder private var icon: some View {
        switch tool.style {
        case .appIcon:
            // Scaled so its own shape, not its canvas, is the body's size.
            image
                .frame(width: bodySize / tool.artworkShare, height: bodySize / tool.artworkShare)
        case .square:
            image
                .frame(width: bodySize, height: bodySize)
                .clipShape(tileShape)
        case let .logo(light, dark):
            let palette = colorScheme == .dark ? light : dark
            let logoSize = bodySize * (Self.logoArea / tool.outlineArea).squareRoot()
            Image(tool.rawValue)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(palette.mark)
                .frame(width: logoSize, height: logoSize)
                .frame(width: bodySize, height: bodySize)
                .background(palette.tile, in: tileShape)
        }
    }

    private var image: some View {
        Image(tool.rawValue)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

private extension Color {
    /// A colour from its hex value, as brand guidelines give them.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 12) {
        ForEach(ToolIcon.Tool.allCases, id: \.self) { tool in
            ToolIcon(tool, size: 64)
        }
    }
    .padding()
}
#endif
