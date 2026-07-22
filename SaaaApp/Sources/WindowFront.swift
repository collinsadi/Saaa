import AppKit

/// Brings a Saaa window to the FRONT and makes the app active. Saaa is a
/// menu-bar accessory; without forced activation, macOS's cooperative
/// activation can leave a freshly shown window behind whatever app has
/// focus. `orderFrontRegardless` guarantees z-order even when the system
/// declines to hand over key status.
@MainActor
enum WindowFront {
    static func present(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
