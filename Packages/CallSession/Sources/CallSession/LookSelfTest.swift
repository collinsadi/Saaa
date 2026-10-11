import Core
import Foundation
import ScreenContext

/// `Saaa --selftest-look`: two real Looks at the frontmost window, timed.
/// Reports counts and timings only, never the text or the window title.
/// It doesn't prompt: without Screen Recording it says so and stops.
public enum LookSelfTest {

    @MainActor
    public static func run() async throws -> String {
        guard ScreenLook.hasPermission else {
            return "skipped: Screen Recording isn't granted to this build"
        }
        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> Int {
            Int(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
        }
        var start = clock.now
        let first = try await SessionController.readScreen()
        let firstTime = clock.now - start
        start = clock.now
        let second = try await SessionController.readScreen()
        let secondTime = clock.now - start
        return """
        app: \(first.appName)
        scene: \(first.scene.rawValue)
        lines: \(first.lineCount)
        characters: \(first.text.count)
        redactions: \(first.redactions)
        truncated: \(first.truncated)
        same text twice: \(first.text == second.text)
        first look: \(milliseconds(firstTime)) ms
        second look: \(milliseconds(secondTime)) ms
        """
    }
}
