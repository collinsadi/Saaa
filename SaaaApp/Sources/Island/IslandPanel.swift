import AppKit
import CallSession
import Core
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

/// Observable outside-click counter (main-actor).
@MainActor
@Observable
final class OutsideClickSignal {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// One-shot welcome trigger: the island introduces itself after onboarding
/// (grows out of the notch, teaches the hotkey, retreats — the retreat IS
/// the lesson about where Saaa lives).
@MainActor
@Observable
final class WelcomePulse {
    private(set) var active = false

    func fire() { active = true }
    func dismiss() { active = false }
}

/// Owns the island panel: creation, notch-centered placement, and
/// re-measurement on display changes. All morphing happens SwiftUI-side —
/// the panel frame never animates.
@MainActor
final class IslandController {

    /// Oversized fixed panel: room for the expanded tier + peek (and the
    /// Live Assist answer block) without ever resizing the window.
    private static let panelSize = NSSize(width: 620, height: 320)

    private var panel: IslandPanel?
    private var screenObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private let callController: CallController
    /// Bumped on any click outside the panel — the root view observes it to
    /// collapse the expanded tier ("Esc/outside collapses, recording
    /// continues"). Global mouse monitors need no extra permission.
    let outsideClick = OutsideClickSignal()
    /// Post-onboarding hello.
    let welcome = WelcomePulse()

    /// Shows the welcome tier (auto-retracts from the root view).
    func showWelcome() {
        welcome.fire()
    }

    init(callController: CallController) {
        self.callController = callController
        install()
        trackDormancy()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.install()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDormancy()
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [outsideClick] _ in
            // Global monitor = clicks in OTHER apps; anything landing on the
            // panel itself arrives via local events instead, so every global
            // click is by definition outside the island.
            outsideClick.bump()
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
        let root = IslandRootView(
            controller: callController, metrics: metrics,
            outsideClick: outsideClick, welcome: welcome)
            .saaaThemed(fixed: .dark)
        panel.contentView = NSHostingView(rootView: AnyView(root))
        panel.orderFrontRegardless()
        self.panel = panel
        CaptureExclusion.shared.register(panel, as: .island)
        applyDormancy()
    }

    /// The oversized panel blocks the window server's resize-cursor bands
    /// for windows underneath it — even where its pixels are zero-alpha
    /// (clicks pass through per-pixel; cursor tracking does not). A dormant
    /// island renders nothing clickable, so the panel ignores mouse events
    /// entirely until a tier becomes visible again.
    private func trackDormancy() {
        withObservationTracking {
            _ = callController.state
            _ = welcome.active
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyDormancy()
                self.trackDormancy()
            }
        }
        applyDormancy()
    }

    private func applyDormancy() {
        let islandShown = (UserDefaults.standard.object(forKey: "showIsland") as? Bool) ?? true
        let dormant: Bool = switch callController.state {
        case .idle, .done: !welcome.active
        default: false
        }
        panel?.ignoresMouseEvents = dormant || !islandShown
    }
}
