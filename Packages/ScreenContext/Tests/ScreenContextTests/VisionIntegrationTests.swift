import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ScreenContext

/// Real Vision OCR over text rendered on the Mac: proves the recognizer and
/// the layout rebuild code the way a Look would see an editor.
@Suite struct VisionIntegrationTests {

    struct RenderFailed: Error {}

    /// Draws each column's lines in Menlo, black on white, like an editor.
    static func render(columns: [(x: CGFloat, text: String)], width: Int = 1_600, fontSize: CGFloat = 26) throws -> CGImage {
        let rows = columns.map { $0.text.components(separatedBy: "\n").count }.max() ?? 1
        let lineHeight = fontSize * 1.6
        let height = Int(CGFloat(rows) * lineHeight + 80)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderFailed() }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        for column in columns {
            for (index, line) in column.text.components(separatedBy: "\n").enumerated() where !line.isEmpty {
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
                context.textPosition = CGPoint(x: column.x, y: CGFloat(height) - 40 - CGFloat(index + 1) * lineHeight)
                CTLineDraw(ctLine, context)
            }
        }
        guard let image = context.makeImage() else { throw RenderFailed() }
        return image
    }

    static func indents(_ text: String) -> [Int] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }
    }

    @Test func recognizesCodeWithItsIndentation() throws {
        let code = """
            def total(items):
                result = 0
                for item in items:
                    if item.active:
                        result += item.price
                return result
            """
        let snapshot = try ScreenLook.snapshot(of: Self.render(columns: [(40, code)]), appName: "Editor")
        #expect(Self.indents(snapshot.text) == Self.indents(code))
        #expect(snapshot.text.contains("result += item.price"))
        #expect(snapshot.scene == .code)
    }

    @Test func keepsAProblemBesideItsEditorApart() throws {
        let problem = """
            Two Sum
            Given an array of integers nums
            and an integer target, return
            indices of the two numbers.
            Example 1:
            Input: nums = [2,7,11,15]
            Output: [0,1]
            Constraints: 2 <= nums.length <= 10^4
            """
        let code = """
            class Solution:
                def twoSum(self, nums, target):
                    seen = {}
                    for i, n in enumerate(nums):
                        pass
            """
        let snapshot = try ScreenLook.snapshot(of: Self.render(columns: [(40, problem), (900, code)]), appName: "Safari")
        let panes = snapshot.text.components(separatedBy: "\n\n\(OCRLayout.paneSeparator)\n\n")
        #expect(panes.count == 2)
        #expect(panes.first?.contains("Given an array of integers nums") == true)
        #expect(panes.last.map(Self.indents) == Self.indents(code))
        #expect(snapshot.scene == .problem)
    }
}
