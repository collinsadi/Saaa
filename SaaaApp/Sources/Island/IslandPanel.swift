import AppKit
import CallSession
import Core
import DesignSystem
import SwiftUI

/// The island's window: a fixed, oversized, borderless, non-activating panel
/// at statusBar+3. Verified contracts: clicks pass through zero-alpha
/// regions per pixel; ANY alpha at menu-bar height swallows menu-bar clicks,
/// so nothing but the black bar itself ever draws up there (no shadows, no
/// glow); the glass panel starts below the bar.
final class IslandPanel: NSPanel {
    /// Key focus only while the live panel (and its Ask field) is open. The
    /// call app stays the active app: typing comes here Spotlight-style.
    var allowsKey = false

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Bumped on any click outside the panel (global monitor = other apps).
@MainActor
@Observable
final class OutsideClickSignal {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// The post-onboarding hello.
@MainActor
@Observable
final class WelcomePulse {
    private(set) var active = false
    func fire() { active = true }
    func dismiss() { active = false }
}

/// Owns the island panel: placement under the notch, re-measurement on
/// display changes, click-through when nothing is showing, and key focus
/// for the Ask field.
@MainActor
final class IslandController {

    private var panel: IslandPanel?
    private var screenObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private let model: AppModel
    let outsideClick = OutsideClickSignal()
    let welcome = WelcomePulse()

    init(model: AppModel) {
        self.model = model
        install()
        track()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyInteractivity() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [outsideClick] _ in
            outsideClick.bump()
        }
    }

    func showWelcome() {
        welcome.fire()
    }

    /// Makes the panel key so the Ask field can take typing.
    func focus() {
        guard let panel else { return }
        panel.allowsKey = true
        panel.makeKey()
    }

    private func install() {
        guard let screen = NotchMetrics.preferredScreen() else { return }
        let metrics = NotchMetrics.measure(screen)
        let size = Size.Island.windowSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width, height: size.height)
        let panel = self.panel ?? IslandPanel(frame: frame)
        panel.setFrame(frame, display: true)
        let root = IslandRootView(model: model, metrics: metrics, outsideClick: outsideClick, welcome: welcome)
            .saaaThemed(fixed: .dark)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        ScreenPrivacy.shared.register(panel, as: .island)
        applyInteractivity()
    }

    private func track() {
        withObservationTracking {
            _ = model.session.phase
            _ = model.session.readySummary
            _ = model.session.summarizing.count
            _ = model.session.imports.count
            _ = model.detector.suggestion
            _ = model.panelExpanded
            _ = welcome.active
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyInteractivity()
                self?.track()
            }
        }
    }

    /// A dormant island renders nothing clickable: the whole panel ignores
    /// the mouse so the windows beneath keep their cursors and clicks.
    private func applyInteractivity() {
        let shown = UserDefaults.standard.object(forKey: SaaaSettings.showIslandKey) as? Bool ?? true
        let session = model.session
        let busy = session.phase != .idle
            || session.readySummary != nil
            || !session.summarizing.isEmpty
            || !session.imports.isEmpty
            || model.detector.suggestion != nil
            || welcome.active
        panel?.ignoresMouseEvents = !(shown && busy)
        let allowsKey = shown && session.isLive && model.panelExpanded
        if panel?.allowsKey != allowsKey {
            panel?.allowsKey = allowsKey
            if !allowsKey, panel?.isKeyWindow == true {
                panel?.makeFirstResponder(nil)
            }
        }
    }
}
