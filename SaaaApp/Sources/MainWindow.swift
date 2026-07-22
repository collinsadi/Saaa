import AppKit
import AudioCapture
import CallSession
import Core
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Which hub pane is showing; externally settable so a hotkey can land the
/// user on a specific pane (Code Assist capture opens with its result).
/// The last pane persists across launches; unknown stored values fall back
/// to Sessions through the failable rawValue initializer.
@MainActor
@Observable
final class HubSelection {
    private static let paneKey = "hubPane"

    var pane: HubPane {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }
    }

    init() {
        pane = UserDefaults.standard.string(forKey: Self.paneKey)
            .flatMap(HubPane.init(rawValue:)) ?? .sessions
    }
}

/// The launchable hub window: one sidebar, five panes — Sessions, Code
/// Assist, Prompts, History, Settings — complementing the ambient island.
/// While the hub is open the app has a Dock presence; closing it returns
/// Saaa to a menu-bar accessory.
@MainActor
final class MainWindowPresenter {

    /// Wired once at launch: Settings ▸ General ▸ "Run setup again".
    var onSetup: () -> Void = {}

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(
        controller: CallController,
        importQueue: ImportQueueModel,
        codeAssist: CodeAssistModel,
        selection: HubSelection
    ) {
        if let window {
            NSApp.setActivationPolicy(.regular)
            WindowFront.present(window)
            return
        }
        let view = MainHubView(
            controller: controller, importQueue: importQueue,
            codeAssist: codeAssist, selection: selection,
            onSetup: { [weak self] in self?.onSetup() })
            .saaaThemed()
        let hosting = NSHostingController(rootView: view)
        // Never let SwiftUI's reported ideal size become window resize
        // constraints — it pins the height (width stays free) and vertical
        // resizing silently dies. The window owns its own limits.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Saaa"
        window.setContentSize(NSSize(width: 960, height: 620))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        // Opacity rides the SwiftUI background, not alphaValue, so text and
        // cards stay at full strength while the base material fades.
        window.isOpaque = false
        window.backgroundColor = .clear
        WindowChrome.applySeamless(to: window)
        window.center()
        self.window = window
        CaptureExclusion.shared.register(window, as: .main)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // Back to menu-bar-only once the hub goes away.
            MainActor.assumeIsolated {
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }
        NSApp.setActivationPolicy(.regular)
        WindowFront.present(window)
    }
}

// MARK: - Import queue

/// Sequential import queue: one file at a time through the live-call
/// pipeline, each ending in Review & Edit; the next starts when the
/// controller returns to idle. Progression is driven by observation of the
/// controller, not by any view — imports advance with the hub closed.
@MainActor
@Observable
final class ImportQueueModel {

    enum ItemStatus: Equatable {
        case waiting
        case processing
        case done
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status: ItemStatus = .waiting
    }

    private(set) var items: [Item] = []
    var context = CallController.ImportContext()
    private var currentID: UUID?
    private var boundController: CallController?

    var hasPending: Bool { items.contains { $0.status == .waiting } }

    /// Wires queue progression to the controller's state, once, at launch.
    func bind(to controller: CallController) {
        guard boundController == nil else { return }
        boundController = controller
        observeState()
    }

    private func observeState() {
        guard let controller = boundController else { return }
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let controller = self.boundController else { return }
                self.stateChanged(controller.state, controller: controller)
                self.observeState()
            }
        }
    }

    /// Adds dropped/picked URLs (folders expand one level, importable
    /// files only) and starts the queue when the controller is free.
    func add(_ urls: [URL], controller: CallController) {
        items += MediaImporter.expand(urls).map { Item(url: $0) }
        startNextIfFree(controller: controller)
    }

    /// Drives the queue off the session state: review closed or error
    /// acknowledged means the pipeline is free again.
    func stateChanged(_ state: SessionState, controller: CallController) {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else {
            startNextIfFree(controller: controller)
            return
        }
        switch state {
        case .done, .idle:
            items[index].status = .done
            self.currentID = nil
            startNextIfFree(controller: controller)
        case .error(let message):
            items[index].status = .failed(message)
            self.currentID = nil
            startNextIfFree(controller: controller)
        default:
            break
        }
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.status {
            case .done, .failed: true
            case .waiting, .processing: false
            }
        }
    }

    private func startNextIfFree(controller: CallController) {
        guard currentID == nil else { return }
        switch controller.state {
        case .idle, .done, .error: break
        default: return
        }
        guard let index = items.firstIndex(where: { $0.status == .waiting }) else { return }
        items[index].status = .processing
        currentID = items[index].id
        controller.importRecording(items[index].url, context: context)
    }
}

// MARK: - Hub view

enum HubPane: String, CaseIterable, Identifiable {
    case sessions
    case codeAssist
    case prompts
    case history
    case settings

    var id: String { rawValue }

    var label: (title: String, icon: String) {
        switch self {
        case .sessions: ("Sessions", "waveform")
        case .codeAssist: ("Code Assist", "chevron.left.forwardslash.chevron.right")
        case .prompts: ("Prompts", "text.quote")
        case .history: ("History", "clock")
        case .settings: ("Settings", "gearshape")
        }
    }

    /// ⌘1–⌘5, in sidebar order.
    var shortcut: KeyEquivalent {
        switch self {
        case .sessions: "1"
        case .codeAssist: "2"
        case .prompts: "3"
        case .history: "4"
        case .settings: "5"
        }
    }
}

struct MainHubView: View {
    let controller: CallController
    let importQueue: ImportQueueModel
    let codeAssist: CodeAssistModel
    @Bindable var selection: HubSelection
    let onSetup: () -> Void

    @Environment(\.saaa) private var saaa
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("hubOpacity") private var hubOpacity = 1.0
    @AppStorage("hubFadeWhenInactive") private var fadeWhenInactive = false

    private var pane: HubPane {
        get { selection.pane }
        nonmutating set { selection.pane = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Size.sidebarWidth)
            Divider()
                .overlay(saaa.borderHairline)
                .ignoresSafeArea(edges: .top)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            saaa.surfaceBase.opacity(HubOpacityPolicy.effective(
                userOpacity: hubOpacity,
                reduceTransparency: reduceTransparency,
                isInactive: activeState == .inactive,
                fadeWhenInactive: fadeWhenInactive))
                .ignoresSafeArea())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.md) {
                BrandMark(size: 16)
                Text("Saaa")
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
            }
            .padding(.bottom, Space.sm)
            InvisibleModeBadge(surface: .main)
                .padding(.bottom, Space.sm)
            ForEach(HubPane.allCases) { item in
                Button {
                    selection.pane = item
                } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: item.label.icon)
                            .frame(width: 18)
                        Text(item.label.title)
                            .font(SaaaFont.body)
                        Spacer()
                        Text("⌘\(String(item.shortcut.character))")
                            .font(SaaaFont.monoCaption)
                            .foregroundStyle(saaa.textTertiary)
                    }
                    .foregroundStyle(pane == item ? saaa.tideText : saaa.textSecondary)
                    .padding(.horizontal, Space.md)
                    .frame(height: Size.controlLg)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(pane == item ? saaa.surfaceInset : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(Space.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .sessions:
            SessionsPane(controller: controller, queue: importQueue)
        case .codeAssist:
            CodeAssistPane(controller: controller, model: codeAssist)
        case .prompts:
            PromptsPane(controller: controller)
        case .history:
            HistoryPane()
        case .settings:
            ScrollView {
                SaaaSettingsView(controller: controller, onSetup: onSetup)
                    .frame(maxWidth: Size.contentColumnMax, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
