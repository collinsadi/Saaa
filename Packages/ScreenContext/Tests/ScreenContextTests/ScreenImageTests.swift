import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenContext

@Suite struct ScreenImageTests {

    /// A white image of the given size.
    func whiteImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Brightness 0...1 of one pixel, (x, y) from the top left.
    func brightness(_ data: Data, x: Int, y: Int) throws -> Double {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }

    @Test func scalesToClaudesSizeAndStaysAJPEG() throws {
        let picture = try #require(ScreenImageEncoder.encode(try whiteImage(width: 3_136, height: 2_000), masking: []))
        #expect(picture.width == 1_568)
        #expect(picture.height == 1_000)
        #expect(picture.mediaType == "image/jpeg")
        #expect(picture.data.starts(with: [0xFF, 0xD8]))
        #expect(picture.maskedRegions == 0)
    }

    @Test func blacksOutSecretLinesAndLeavesTheRest() throws {
        let fragments = [
            TextFragment(text: "let key = \"sk-ant-api03-abcdefghijklmnopqrstuvwxyz\"", box: CGRect(x: 100, y: 50, width: 400, height: 30)),
            TextFragment(text: "func load() -> Data {", box: CGRect(x: 100, y: 200, width: 300, height: 30)),
        ]
        let boxes = ScreenImageEncoder.secretBoxes(fragments)
        #expect(boxes == [fragments[0].box])
        let picture = try #require(ScreenImageEncoder.encode(try whiteImage(width: 800, height: 400), masking: boxes))
        #expect(picture.maskedRegions == 1)
        // Inside the secret's box (top-left origin): black. Elsewhere: white.
        #expect(try brightness(picture.data, x: 300, y: 65) < 0.1)
        #expect(try brightness(picture.data, x: 300, y: 215) > 0.9)
        #expect(try brightness(picture.data, x: 700, y: 350) > 0.9)
    }
}
