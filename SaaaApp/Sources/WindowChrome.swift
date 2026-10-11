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

/// Saaa is a menu-bar accessory until a regular window (the hub, setup) is
/// open; then it gets a Dock icon and a place in the app switcher, and it
/// goes back to the menu bar when the last such window closes.
@MainActor
enum AppPresence {
    private static let identifier = NSUserInterfaceItemIdentifier("saaa.regular-window")
    private static var observed: Set<ObjectIdentifier> = []

    static func adopt(_ window: NSWindow) {
        window.identifier = identifier
        NSApp.setActivationPolicy(.regular)
        let key = ObjectIdentifier(window)
        guard observed.insert(key).inserted else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                let othersOpen = NSApp.windows.contains {
                    $0 !== window && $0.isVisible && $0.identifier == identifier
                }
                if !othersOpen {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
