import AnthropicKit
import AppKit
import CallSession
import Copilot
import Core
import CryptoKit
import Foundation
import Observation
import Persistence
import os

/// The hub panes, in sidebar order.
enum HubPane: String, CaseIterable, Identifiable, Hashable {
    case home
    case sessions
    case memory
    case playbooks
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .sessions: "Sessions"
        case .memory: "Ask all calls"
        case .playbooks: "Playbooks"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .sessions: "waveform.badge.magnifyingglass"
        case .memory: "text.magnifyingglass"
        case .playbooks: "books.vertical"
        case .settings: "gearshape"
        }
    }
}

/// App-wide state: the session controller, playbooks, the library list, and
/// which surfaces are showing. One instance, created at launch.
@MainActor
@Observable
final class AppModel {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "App")

    let library: SessionLibrary
    let session: SessionController
    let detector: MeetingDetector
    /// Code help outside calls: Look, Watch and the problem ladder.
    let codeAssist: CodeAssistEngine
    /// Ask all calls, and the prep brief from past calls.
    let memory: MemoryEngine
    /// False when the content key could not be read: sessions this run
    /// can't be reopened later, and the UI says so.
    let encryptionHealthy: Bool

    private(set) var playbooks: PlaybookLibrary
    private(set) var sessions: [SessionIndexEntry] = []
    private(set) var monthlyCost: Double = 0
    /// Claude is connected through the Saaa relay.
    private(set) var hasAPIKey = RelayConnectionStore.shared.isConnected

    // Surfaces
    var hubPane: HubPane = .home
    var selectedSessionID: UUID?
    /// The live panel under the island is open.
    var panelExpanded = false
    /// Bumped to move keyboard focus into the live panel's Ask field.
    var askFocusToken = 0
    /// The live consent banner was handled for this session.
    var consentHandled = false
    /// Editor windows with the Saaa extension connected, as "App (workspace)".
    private(set) var editorConnections: [String] = []
    /// ⌥⌘L and Code Assist outside calls.
    var codeAssistEnabled = UserDefaults.standard.bool(forKey: CodeAssistSettings.enabledKey) {
        didSet { UserDefaults.standard.set(codeAssistEnabled, forKey: CodeAssistSettings.enabledKey) }
    }

    @ObservationIgnored private let playbookStore: PlaybookStore
    @ObservationIgnored private let encryption: EncryptionService

    // Presenters, wired by the app at launch.
    @ObservationIgnored var openHubAction: (HubPane?) -> Void = { _ in }
    @ObservationIgnored var openPrepAction: (SessionContext, Playbook?) -> Void = { _, _ in }
    @ObservationIgnored var focusIslandAction: () -> Void = {}
    @ObservationIgnored var runOnboardingAction: () -> Void = {}
    @ObservationIgnored var openCodeAssistAction: () -> Void = {}

    init() {
        let encryption: EncryptionService
        var healthy = true
        do {
            encryption = try EncryptionService()
        } catch {
            Self.log.error("content key unavailable: \(String(describing: error), privacy: .public)")
            encryption = EncryptionService(key: SymmetricKey(size: .bits256))
            healthy = false
        }
        self.encryption = encryption
        encryptionHealthy = healthy
        let library = SessionLibrary(encryption: encryption)
        self.library = library
        playbookStore = PlaybookStore(encryption: encryption)
        playbooks = playbookStore.load()

        let session = SessionController(library: library, playbooks: { PlaybookLibrary() })
        self.session = session
        detector = MeetingDetector(isBusy: { session.isBusy })
        codeAssist = CodeAssistEngine(
            service: AnthropicClient.relay(),
            screenReader: { try await CodeAssistBridge.readScreen() },
            environment: { CodeAssistBridge.environment() },
            isCallLive: { session.isLive },
            prewarm: { CodeAssistBridge.prewarm() })
        memory = MemoryEngine(service: AnthropicClient.relay(), index: { await library.memoryIndex() })

        // The real provider needs `self`; rebind now that it exists.
        session.playbookProvider = { [weak self] in self?.playbooks ?? PlaybookLibrary() }
        session.onLibraryChange = { [weak self] in self?.refreshLibrary() }

        migrateLegacyData()
        refreshLibrary()
        detector.start()
        CodeAssistBridge.startEditorBridge { [weak self] connections in
            Task { @MainActor in self?.editorConnections = connections }
        }
    }

    // MARK: - Library

    func refreshLibrary() {
        Task {
            sessions = await library.entries()
            monthlyCost = await library.monthlyCost() + MonthlyUsage.total(defaults: .standard)
        }
    }

    func record(_ id: UUID) async -> SessionRecord? {
        try? await library.record(id)
    }

    func update(_ record: SessionRecord) {
        Task {
            _ = try? await library.update(record)
            refreshLibrary()
        }
    }

    func delete(_ id: UUID) {
        Task {
            try? await library.delete(id)
            if selectedSessionID == id { selectedSessionID = nil }
            refreshLibrary()
        }
    }

    func deleteAllSessions() {
        Task {
            try? await library.deleteAll()
            selectedSessionID = nil
            refreshLibrary()
        }
    }

    /// One-time adoption of pre-rebuild sessions and prompts.
    private func migrateLegacyData() {
        Task {
            let adopted = await library.adoptUnindexedSessions()
            if adopted > 0 { refreshLibrary() }
        }
        if !UserDefaults.standard.bool(forKey: LegacyPrompts.migratedKey) {
            if let carried = LegacyPrompts.playbook(encryption: encryption) {
                var library = playbooks
                library.upsert(carried)
                savePlaybooks(library)
            }
            UserDefaults.standard.set(true, forKey: LegacyPrompts.migratedKey)
        }
    }

    // MARK: - Playbooks

    func savePlaybooks(_ library: PlaybookLibrary) {
        playbooks = library
        do {
            try playbookStore.save(library)
        } catch {
            Self.log.error("playbooks not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Saves a playbook; edits to the one in use reach the live call at once.
    func upsertPlaybook(_ playbook: Playbook) {
        var library = playbooks
        library.upsert(playbook)
        savePlaybooks(library)
        if session.isLive, session.playbook.id == playbook.id {
            session.switchPlaybook(playbook)
        }
    }

    /// Deletes a custom playbook or resets an edited built-in.
    func removePlaybook(_ id: String) {
        var library = playbooks
        library.remove(id: id)
        savePlaybooks(library)
        if session.isLive, session.playbook.id == id {
            session.switchPlaybook(library.playbook(id: id) ?? library.defaultPlaybook)
        }
    }

    func setDefaultPlaybook(_ id: String) {
        var library = playbooks
        library.defaultID = id
        savePlaybooks(library)
    }

    // MARK: - Session

    func refreshKeyState() {
        hasAPIKey = RelayConnectionStore.shared.isConnected
    }

    func startSession(playbook: Playbook? = nil, context: SessionContext? = nil) {
        consentHandled = false
        session.start(playbook: playbook, context: context)
        detector.dismiss()
    }

    func startSuggested() {
        guard let suggestion = detector.suggestion else { return }
        let context = suggestion.event.map { SessionContext.from($0.context) }
        let playbook = suggestion.event.flatMap { PlaybookMatcher.match(title: $0.title, in: playbooks.all) }
        startSession(playbook: playbook, context: context)
    }

    func toggleSession() {
        if session.phase == .idle || session.phase.isFailure {
            consentHandled = false
        }
        session.toggle()
    }

    /// ⌥⌘A: answer what they just asked.
    func answerNow() {
        guard session.isLive, let copilot = session.copilot else { return }
        if copilot.pendingQuestion != nil {
            copilot.answerPending()
        } else if let action = session.playbook.quickActions.first(where: { $0.kind == .answer }) {
            copilot.run(action)
        } else {
            copilot.run(StandardActions.answer)
        }
        panelExpanded = true
    }

    /// ⌥⌘K: open the panel with the Ask field focused.
    func focusAsk() {
        guard session.isLive else { return }
        panelExpanded = true
        askFocusToken += 1
        focusIslandAction()
    }

    /// ⌥⌘L, the panel's Look button or the menu: read the frontmost window
    /// on this Mac and answer with the call and the screen together. Text
    /// typed in the Ask field becomes the question.
    func lookAtScreen(question: String? = nil) {
        guard session.isLive, let copilot = session.copilot, copilot.canLook else { return }
        copilot.look(question: question)
        panelExpanded = true
    }

    /// ⌥⌘L: Look in the live panel during a call; Code Assist otherwise.
    func lookHotkey() {
        if session.isLive {
            lookAtScreen()
        } else if codeAssistEnabled {
            codeLook()
        }
    }

    func openCodeAssist() {
        openCodeAssistAction()
    }

    /// Opens Code Assist and reads the window in front.
    func codeLook(question: String? = nil) {
        openCodeAssist()
        codeAssist.look(question: question)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openHub(_ pane: HubPane? = nil) {
        if let pane { hubPane = pane }
        openHubAction(pane)
    }

    func openSession(_ id: UUID) {
        selectedSessionID = id
        hubPane = .sessions
        openHubAction(.sessions)
    }

    func openPrep(context: SessionContext? = nil, playbook: Playbook? = nil) {
        openPrepAction(context ?? (session.isLive ? session.context : SessionContext()), playbook)
    }
}

extension SessionController.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
