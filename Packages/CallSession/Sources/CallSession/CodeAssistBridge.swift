import AppKit
import Copilot
import Core
import ScreenContext

/// What Code Assist needs from the Mac, here so the app links one package.
public enum CodeAssistBridge {

    /// A Look outside a call: the same read a call's Look makes.
    @MainActor
    public static func readScreen(withImage: Bool = false) async throws -> ScreenSnapshot {
        try await SessionController.readScreen(withImage: withImage)
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

    /// Opens the local socket editor extensions connect to, and reports the
    /// connected windows as "App (workspace)". Without it, Look reads the
    /// screen as before.
    public static func startEditorBridge(onChange: @escaping @Sendable ([String]) -> Void) {
        do {
            try EditorBridge.shared.start()
        } catch {
            return
        }
        EditorBridge.shared.onPeersChange { peers in
            onChange(peers.map { peer in
                guard let workspace = peer.workspace, !workspace.isEmpty else { return peer.app }
                return "\(peer.app) (\(workspace))"
            })
        }
    }
}
