import CoreGraphics
@testable import ScreenContext

/// A fragment in a 10-pixel-per-character monospaced world, 20 pixels tall.
func frag(_ text: String, x: Double, y: Double, charWidth: Double = 10, height: Double = 20) -> TextFragment {
    TextFragment(text: text, box: CGRect(x: x, y: y, width: Double(text.count) * charWidth, height: height))
}
