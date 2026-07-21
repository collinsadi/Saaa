import AppKit

/// Runtime notch measurement — never hardcoded (22–38 pt across models and
/// scaling; this machine's Air measures 179×32 pt). Re-derived whenever
/// screen parameters change.
struct NotchMetrics: Equatable {
    let screenFrame: NSRect
    /// Physical notch width; 0 on no-notch Macs.
    let notchWidth: CGFloat
    /// Notch (safe-area top) height; menu-bar height on no-notch Macs.
    let topInset: CGFloat

    var hasNotch: Bool { notchWidth > 0 }

    /// The verified formula: width = frame.width − auxiliaryTopLeftArea −
    /// auxiliaryTopRightArea; height = safeAreaInsets.top.
    static func measure(_ screen: NSScreen) -> NotchMetrics {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchMetrics(
                screenFrame: screen.frame,
                notchWidth: screen.frame.width - left.width - right.width,
                topInset: screen.safeAreaInsets.top)
        }
        // No notch: the fallback capsule floats below the menu bar.
        let menuBarHeight = screen.frame.height - screen.visibleFrame.maxY
        return NotchMetrics(
            screenFrame: screen.frame,
            notchWidth: 0,
            topInset: max(24, menuBarHeight))
    }

    /// The screen hosting the island: the one with a notch, else the main.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.auxiliaryTopLeftArea != nil && $0.safeAreaInsets.top > 0
        } ?? NSScreen.main
    }
}
