import AppKit
import CallSession
import DesignSystem
import SwiftUI

/// The island's window: a fixed, oversized, borderless, non-activating panel
/// per display, level statusBar+3. Verified contracts (probed on this
/// hardware): clicks pass through zero-alpha regions per-pixel; ANY alpha at
/// menu-bar height swallows menu-bar clicks — so the panel draws NO shadows
/// or glows, ever; the window-server click region tracks SwiftUI shape
/// changes within ~300 ms.
final class IslandPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // any alpha at menu-bar height swallows clicks
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the island panel: creation, notch-centered placement, and
/// re-measurement on display changes. All morphing happens SwiftUI-side —
/// the panel frame never animates.
@MainActor
final class IslandController {

    /// Oversized fixed panel: room for the expanded tier + peek without ever
    /// resizing the window.
    private static let panelSize = NSSize(width: 620, height: 260)

    private var panel: IslandPanel?
    private var screenObserver: NSObjectProtocol?
    private let callController: CallController

    init(callController: CallController) {
        self.callController = callController
        install()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.install()
            }
        }
    }

    private func install() {
        guard let screen = NotchMetrics.preferredScreen() else { return }
        let metrics = NotchMetrics.measure(screen)

        let frame = NSRect(
            x: screen.frame.midX - Self.panelSize.width / 2,
            y: screen.frame.maxY - Self.panelSize.height,
            width: Self.panelSize.width,
            height: Self.panelSize.height)

        let panel = self.panel ?? IslandPanel(frame: frame)
        panel.setFrame(frame, display: true)
        let root = IslandRootView(controller: callController, metrics: metrics)
            .saaaThemed(fixed: .dark)
        panel.contentView = NSHostingView(rootView: AnyView(root))
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
