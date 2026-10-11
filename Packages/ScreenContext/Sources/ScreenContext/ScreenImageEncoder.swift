import Core
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The one picture Send image sends: the captured window scaled to the
/// size Claude reads, every line the redactor would mask blacked out, as a
/// JPEG in memory. Nothing here touches the disk.
enum ScreenImageEncoder {

    /// Claude scales longer edges down to about this anyway.
    static let maxLongEdge = 1_568
    static let quality = 0.8
    /// Extra pixels blacked out around a secret line.
    static let padding = 3.0

    /// Recognized lines that hold something secret-looking, as boxes in
    /// image pixels with a top-left origin.
    static func secretBoxes(_ fragments: [TextFragment]) -> [CGRect] {
        fragments.filter { SecretRedactor.redact($0.text).count > 0 }.map(\.box)
    }

    static func encode(_ image: CGImage, masking boxes: [CGRect]) -> ScreenImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, Double(maxLongEdge) / max(width, height))
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for box in boxes {
            // Boxes have a top-left origin; the context's is at the bottom left.
            let x = Double(box.minX) * scale - padding
            let y = (height - Double(box.maxY)) * scale - padding
            let w = Double(box.width) * scale + 2 * padding
            let h = Double(box.height) * scale + 2 * padding
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        guard let masked = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, masked, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ScreenImage(
            data: data as Data, mediaType: "image/jpeg", width: targetWidth, height: targetHeight, maskedRegions: boxes.count)
    }
}
