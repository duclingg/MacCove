import AppKit
import ImageIO

/// Album art decoded, downsampled and colour-sampled off the main thread, so
/// a track change never stalls the island while it animates.
///
/// Players hand over full-size artwork (often 1000px or more), which is far
/// larger than the 64pt the island ever draws.
nonisolated struct ProcessedArtwork: @unchecked Sendable {
    // CGImage and NSColor are immutable once created, so sharing them across
    // threads is safe.
    let image: CGImage
    /// Accent derived from the artwork, lifted so it reads on black.
    let tint: NSColor

    /// Enough pixels for 64pt artwork on a 2x display, with some headroom.
    private static let maxPixelSize = 192
    private static let sampleSize = 8

    @concurrent
    static func make(fromBase64 base64: String) async -> ProcessedArtwork? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return ProcessedArtwork(image: image, tint: tint(for: image))
    }

    /// The image's average colour, kept bright enough to stay legible on the
    /// island's black background. Near-grey artwork falls back to soft white.
    private static func tint(for image: CGImage) -> NSColor {
        let fallback = NSColor(white: 0.92, alpha: 1)
        let side = sampleSize
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return fallback }

        var red = 0, green = 0, blue = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            red += Int(pixels[offset])
            green += Int(pixels[offset + 1])
            blue += Int(pixels[offset + 2])
        }
        let count = CGFloat(side * side) * 255
        let average = NSColor(
            srgbRed: CGFloat(red) / count,
            green: CGFloat(green) / count,
            blue: CGFloat(blue) / count,
            alpha: 1
        )

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.12 else { return fallback }
        return NSColor(
            hue: hue,
            saturation: min(max(saturation * 1.2, 0.4), 0.62),
            brightness: max(brightness, 0.96),
            alpha: 1
        )
    }
}
