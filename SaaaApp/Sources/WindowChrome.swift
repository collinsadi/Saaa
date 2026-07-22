import AppKit

/// Seamless window treatment (UI-PLAN §4.2): no stock titlebar strip — the
/// content runs edge-to-edge to the window top and the native traffic lights
/// float inside the app surface. The title stays set for accessibility and
/// the Window menu; only its visibility goes.
///
/// Compatible with the (deferred) hub translucency feature: this changes
/// titlebar treatment only and never forces `isOpaque`.
@MainActor
enum WindowChrome {
    static func applySeamless(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
    }
}
