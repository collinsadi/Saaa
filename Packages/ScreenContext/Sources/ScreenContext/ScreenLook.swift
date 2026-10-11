import Core
import CoreGraphics
import Foundation

/// A Look: read the frontmost window's text on this Mac and hand back a
/// redacted snapshot. The screenshot exists only inside this call; what
/// leaves it is text, after `SecretRedactor`.
public enum ScreenLook {

    /// About 3,000 tokens of screen text per Look.
    public static let maxCharacters = 12_000

    /// Screen Recording is allowed (no prompt).
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Loads the on-device text model before the first Look. The first
    /// recognition after install can take many seconds; later ones take a
    /// fraction of a second.
    public static func prewarm() {
        Task.detached(priority: .utility) {
            guard let image = ScreenTextRecognizer.sampleImage() else { return }
            _ = try? ScreenTextRecognizer.fragments(in: image)
        }
    }

    /// Reads the frontmost window. `frontmostPID` is the active app, read
    /// on the main actor by the caller; `excludingPID` is Saaa itself.
    public static func snapshot(frontmostPID: pid_t?, excludingPID: pid_t) async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; the grant takes
            // effect after Saaa restarts.
            CGRequestScreenCaptureAccess()
            throw ScreenReadError.permissionNeeded
        }
        guard let target = WindowCapture.frontmostTarget(preferring: frontmostPID, excluding: excludingPID) else {
            throw ScreenReadError.noWindow
        }
        let captured: (image: CGImage, title: String?)
        do {
            captured = try await WindowCapture.capture(target)
        } catch let error as ScreenReadError {
            throw error
        } catch {
            throw ScreenReadError.failed(String(describing: type(of: error)))
        }
        return try snapshot(of: captured.image, appName: target.ownerName, windowTitle: captured.title)
    }

    /// A Look at an image already in hand: on-device OCR, then `compose`.
    public static func snapshot(of image: CGImage, appName: String, windowTitle: String? = nil) throws -> ScreenSnapshot {
        let fragments: [TextFragment]
        do {
            fragments = try ScreenTextRecognizer.fragments(in: image)
        } catch {
            throw ScreenReadError.failed(String(describing: type(of: error)))
        }
        return try compose(fragments: fragments, appName: appName, windowTitle: windowTitle)
    }

    /// The pure end of a Look: layout, redaction, the size cap, the scene.
    public static func compose(
        fragments: [TextFragment], appName: String, windowTitle: String?,
        limit: Int = maxCharacters, now: Date = .now
    ) throws -> ScreenSnapshot {
        let assembled = OCRLayout.assemble(fragments)
        guard !assembled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenReadError.nothingReadable
        }
        let redacted = SecretRedactor.redact(assembled)
        var text = redacted.text
        var truncated = false
        if text.count > limit {
            text = String(text.prefix(limit))
            if let cut = text.lastIndex(of: "\n") { text = String(text[..<cut]) }
            truncated = true
        }
        let title = windowTitle.map { SecretRedactor.redact($0).text }
        return ScreenSnapshot(
            appName: appName.isEmpty ? "Screen" : appName, windowTitle: title, text: text,
            scene: SceneClassifier.classify(text), redactions: redacted.count,
            truncated: truncated, capturedAt: now)
    }
}
