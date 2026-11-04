//
//  AppIcon.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import SwiftUI

extension ShapeStyle where Self == Color {
    /// The design's green for something that finished well.
    static var islandSucceeded: Color {
        Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    }

    /// Softer than the system red, so error text reads on black.
    static var islandError: Color {
        Color(red: 1, green: 105 / 255, blue: 97 / 255)
    }
}

/// An app's own icon, as Xcode or the terminal a command ran in, or a
/// symbol when the app can't be found.
struct AppIcon: View {
    let bundleIdentifier: String?
    /// The visible tile. App icons leave a transparent margin around it,
    /// so the image is drawn a little larger than this.
    let size: CGFloat
    let fallbackSystemName: String
    var fallbackTint: Color = .white

    /// macOS app icons fill about 80% of their canvas.
    private static let marginScale: CGFloat = 1.22
    /// Looked up once per app; icons don't change while MacCove runs.
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let image = Self.image(for: bundleIdentifier) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * Self.marginScale, height: size * Self.marginScale)
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: (size * 0.7).rounded(), weight: .medium))
                    .foregroundStyle(fallbackTint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func image(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let cached = cache[bundleIdentifier] {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        cache[bundleIdentifier] = image
        return image
    }
}
