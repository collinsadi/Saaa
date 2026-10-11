import Core
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The window a Look reads.
struct WindowTarget: Sendable, Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bounds: CGRect
    /// Only with Screen Recording allowed; nil otherwise.
    var title: String? = nil
}

enum WindowCapture {

    /// The frontmost normal window, preferring the frontmost app's and never
    /// Saaa's own. With `.optionOnScreenOnly` the window server lists
    /// windows front to back.
    static func frontmostTarget(preferring preferred: pid_t?, excluding excluded: pid_t) -> WindowTarget? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let candidates = list.compactMap { info -> WindowTarget? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerPID as String] as? Int, owner != Int(excluded),
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            return WindowTarget(
                windowID: CGWindowID(number), ownerPID: pid_t(owner),
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "", bounds: bounds,
                title: info[kCGWindowName as String] as? String)
        }
        if let preferred, let match = candidates.first(where: { $0.ownerPID == preferred }) {
            return match
        }
        return candidates.first
    }

    /// One frame of one window through ScreenCaptureKit, long edge capped
    /// so OCR stays quick. The image never leaves this module.
    static func capture(_ target: WindowTarget, maxLongEdge: Double = 2_560) async throws -> (image: CGImage, title: String?) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
            throw ScreenReadError.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        var width = Double(filter.contentRect.width) * scale
        var height = Double(filter.contentRect.height) * scale
        let longEdge = max(width, height)
        if longEdge > maxLongEdge {
            width *= maxLongEdge / longEdge
            height *= maxLongEdge / longEdge
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(width.rounded()))
        configuration.height = max(1, Int(height.rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, window.title)
    }
}
