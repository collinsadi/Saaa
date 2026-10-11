import CoreGraphics
import CoreText
import Foundation
import Vision

/// On-device text recognition with Vision, the same request the earlier
/// Code Assist used: accurate level, no language correction (code is not
/// prose). Boxes come back in image pixels with a top-left origin.
enum ScreenTextRecognizer {

    static func fragments(in image: CGImage) throws -> [TextFragment] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let width = Double(image.width)
        let height = Double(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision boxes are normalized with the origin at the bottom left.
            let box = observation.boundingBox
            return TextFragment(
                text: candidate.string,
                box: CGRect(
                    x: box.minX * width, y: (1 - box.maxY) * height,
                    width: box.width * width, height: box.height * height))
        }
    }

    /// One short word, black on white: enough for Vision to load its model.
    static func sampleImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 160, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 48))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 24, nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        context.textPosition = CGPoint(x: 12, y: 14)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Saaa", attributes: attributes)), context)
        return context.makeImage()
    }
}
