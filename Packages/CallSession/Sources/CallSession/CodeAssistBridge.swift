import AppKit
import Copilot
import Core
import ScreenContext

/// What Code Assist needs from the Mac, here so the app links one package.
public enum CodeAssistBridge {

    /// A Look outside a call: the same read a call's Look makes.
    @MainActor
    public static func readScreen() async throws -> ScreenSnapshot {
        try await SessionController.readScreen()
    }

    /// What Watch checks each tick: the app in front, its front window and
    /// the time since the last key press. No capture, no permission.
    @MainActor
    public static func environment() -> WatchEnvironment {
        let front = NSWorkspace.shared.frontmostApplication
        return WatchEnvironment(
            bundleID: front?.bundleIdentifier,
            appName: front?.localizedName ?? "",
            windowID: ScreenLook.frontWindowID(
                frontmostPID: front?.processIdentifier, excludingPID: ProcessInfo.processInfo.processIdentifier),
            secondsSinceTyping: ScreenLook.secondsSinceTyping())
    }

    /// Loads Vision's text model ahead of the first read.
    public static func prewarm() {
        if ScreenLook.hasPermission { ScreenLook.prewarm() }
    }
}
