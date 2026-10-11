import AppKit
import CallSession
import Core
import DesignSystem
import SwiftUI

/// The island's window: a fixed, oversized, borderless, non-activating panel
/// at statusBar+3. It takes the mouse only while the pointer is over
/// something it draws (``IslandHitArea``); everywhere else, including the
/// empty rest of its frame, clicks and hovers go to the apps beneath.
/// Nothing but the black bar draws at menu-bar height; the glass panel
/// starts below the bar.
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
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Where the island draws something you can click, in the panel's
/// top-left coordinates, reported by the views themselves.
@MainActor
final class IslandHitArea {
    var island: CGRect = .zero {
        didSet { if island != oldValue { onChange() } }
    }
    var panel: CGRect = .zero {
        didSet { if panel != oldValue { onChange() } }
    }
    var onChange: () -> Void = {}

    func contains(_ point: CGPoint) -> Bool {
        [island, panel].contains { rect in
            rect.width > 1 && rect.height > 1 && rect.insetBy(dx: -2, dy: -2).contains(point)
        }
    }
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
    private var moveMonitors: [Any] = []
    /// Polls the pointer while something shows: moves over the menu bar or
    /// Saaa's own windows don't reach either event monitor.
    private var pointerTimer: Timer?
    private let model: AppModel
    /// Something is showing (a session, a result, a suggestion).
    private var interactive = false
    let outsideClick = OutsideClickSignal()
    let welcome = WelcomePulse()
    let hitArea = IslandHitArea()

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
        // The pointer decides whether the panel takes the mouse: other apps'
        // moves arrive on the global monitor, ours on the local one.
        hitArea.onChange = { [weak self] in self?.updateMousePassThrough() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.updateMousePassThrough()
        }) {
            moveMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            self?.updateMousePassThrough()
            return event
        }) {
            moveMonitors.append(local)
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
        let root = IslandRootView(
            model: model, metrics: metrics, outsideClick: outsideClick, welcome: welcome, hitArea: hitArea)
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

    /// A dormant island takes no mouse events at all; a showing one takes
    /// them only under the pointer's current position on its content.
    private func applyInteractivity() {
        let shown = UserDefaults.standard.object(forKey: SaaaSettings.showIslandKey) as? Bool ?? true
        let session = model.session
        let busy = session.phase != .idle
            || session.readySummary != nil
            || !session.summarizing.isEmpty
            || !session.imports.isEmpty
            || model.detector.suggestion != nil
            || welcome.active
        interactive = shown && busy
        if interactive, pointerTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMousePassThrough() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        } else if !interactive {
            pointerTimer?.invalidate()
            pointerTimer = nil
        }
        updateMousePassThrough()
        let allowsKey = shown && session.isLive && model.panelExpanded
        if panel?.allowsKey != allowsKey {
            panel?.allowsKey = allowsKey
            if !allowsKey, panel?.isKeyWindow == true {
                panel?.makeFirstResponder(nil)
            }
        }
    }
}

extension IslandController {
    /// Explicitly setting `ignoresMouseEvents = false` makes the whole frame
    /// catch clicks, transparent or not, so the panel only accepts the mouse
    /// while the pointer is over the bar, a tier or the live panel.
    fileprivate func updateMousePassThrough() {
        guard let panel else { return }
        var accepts = false
        if interactive {
            let mouse = NSEvent.mouseLocation
            let frame = panel.frame
            accepts = hitArea.contains(CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y))
        }
        if panel.ignoresMouseEvents == accepts {
            panel.ignoresMouseEvents = !accepts
        }
    }
}
