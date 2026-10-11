import AppKit
import CallSession
import Copilot
import Core
import DesignSystem
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Saaa: a live copilot for calls. Menu-bar first; the island under the
/// notch while a session runs; the hub for everything after.
@main
struct SaaaApp: App {
    @NSApplicationDelegateAdaptor(SaaaAppDelegate.self) private var appDelegate
    @State private var shell: AppShell?

    init() {
        if let name = SelfTests.requested {
            SelfTests.run(name)
            _shell = State(initialValue: nil)
        } else {
            _shell = State(initialValue: AppShell())
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let shell {
                SaaaMenu(shell: shell, model: shell.model)
            } else {
                Text("Running a self-test…")
            }
        } label: {
            MenuBarLabel(session: shell?.model.session, hintWaiting: (shell?.model.codeAssist.unread ?? 0) > 0)
        }
    }
}

/// Finder "Open with Saaa" and Dock clicks.
final class SaaaAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openHandler: (([URL]) -> Void)?
    @MainActor static var reopenHandler: (() -> Void)?
    @MainActor private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            if let handler = SaaaAppDelegate.openHandler {
                handler(urls)
            } else {
                SaaaAppDelegate.pending.append(contentsOf: urls)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            SaaaAppDelegate.reopenHandler?()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    static func takePending() -> [URL] {
        defer { pending = [] }
        return pending
    }
}

/// Owns the model and every surface for the life of the app.
@MainActor
final class AppShell {
    let model: AppModel
    let about = AboutPresenter()
    private let island: IslandController
    private let hub: HubPresenter
    private let prep: PrepPresenter
    private let onboarding: OnboardingPresenter
    private let codeAssist: CodeAssistPresenter
    private var hotkeys: [HotkeyMonitor] = []
    /// ⌥⌘L, held only while a session is live.
    private var lookHotkey: HotkeyMonitor?

    init() {
        let model = AppModel()
        self.model = model
        let hub = HubPresenter(model: model)
        let prep = PrepPresenter(model: model)
        let island = IslandController(model: model)
        self.hub = hub
        self.prep = prep
        self.island = island
        onboarding = OnboardingPresenter(model: model)
        let codeAssist = CodeAssistPresenter(model: model)
        self.codeAssist = codeAssist
        model.openCodeAssistAction = { codeAssist.show() }

        model.openHubAction = { _ in hub.show() }
        model.openPrepAction = { context, playbook in prep.show(context: context, playbook: playbook) }
        model.focusIslandAction = { island.focus() }
        model.runOnboardingAction = { [weak self] in self?.runOnboarding() }

        // ⌥⌘R start/stop, ⌥⌘A answer now, ⌥⌘K ask. Global, so they work
        // with the call app in front.
        hotkeys = [
            HotkeyMonitor(binding: .optionCommandR, id: 1) { [weak model] in model?.toggleSession() },
            HotkeyMonitor(binding: .optionCommandA, id: 2) { [weak model] in model?.answerNow() },
            HotkeyMonitor(binding: .optionCommandK, id: 3) { [weak model] in model?.focusAsk() },
        ]
        trackLiveHotkeys()

        SaaaAppDelegate.openHandler = { [weak self] urls in self?.importFiles(urls) }
        SaaaAppDelegate.reopenHandler = { [weak self] in self?.model.openHub() }
        let pending = SaaaAppDelegate.takePending()
        if !pending.isEmpty {
            importFiles(pending)
        }

        if !UserDefaults.standard.bool(forKey: SaaaSettings.onboardingCompleteKey) {
            Task { @MainActor [weak self] in
                self?.runOnboarding()
            }
        }
    }

    /// Registers ⌥⌘L while a session is live or Code Assist is on, and
    /// releases it otherwise, so Finder and Safari keep their Downloads
    /// shortcut the rest of the time.
    private func trackLiveHotkeys() {
        let wanted = withObservationTracking {
            model.session.isLive || model.codeAssistEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackLiveHotkeys() }
        }
        if wanted, lookHotkey == nil {
            lookHotkey = HotkeyMonitor(binding: .optionCommandL, id: 4) { [weak model] in model?.lookHotkey() }
        } else if !wanted {
            lookHotkey = nil
        }
    }

    func runOnboarding() {
        onboarding.show { [weak self] in
            self?.model.refreshKeyState()
            self?.island.showWelcome()
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        model.openHub(.sessions)
        for url in urls {
            model.session.importRecording(url)
        }
    }

    /// Menu: pick recordings to transcribe and summarize.
    func chooseRecordings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose recordings. Saaa transcribes them on this Mac."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }
}

/// The menu-bar glyph: the brand mark at rest, a record glyph while live,
/// a lightbulb when Watch has a hint waiting.
struct MenuBarLabel: View {
    let session: SessionController?
    var hintWaiting = false

    var body: some View {
        if let session, session.isLive {
            Image(systemName: session.micMuted ? "mic.slash.circle" : "record.circle")
                .accessibilityLabel("Saaa, recording")
        } else if let session, session.isBusy || !session.summarizing.isEmpty || !session.imports.isEmpty {
            Image(systemName: "waveform.circle")
                .accessibilityLabel("Saaa, working")
        } else if hintWaiting {
            Image(systemName: "lightbulb.fill")
                .accessibilityLabel("Saaa, a code hint is waiting")
        } else {
            Image("MenuBarIcon")
                .accessibilityLabel("Saaa")
        }
    }
}

/// The menu-bar menu: status, session controls, then destinations.
struct SaaaMenu: View {
    let shell: AppShell
    @Bindable var model: AppModel

    var body: some View {
        status
        Divider()
        controls
        Divider()
        Button("Open Saaa") { model.openHub(.home) }
            .keyboardShortcut("o")
        Button("Sessions") { model.openHub(.sessions) }
        Button("Playbooks") { model.openHub(.playbooks) }
        Button("Settings…") { model.openHub(.settings) }
            .keyboardShortcut(",")
        Button("Import a recording…") { shell.chooseRecordings() }
        Divider()
        Button("About Saaa") { shell.about.show() }
        Button("Quit Saaa") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var status: some View {
        let session = model.session
        switch session.phase {
        case .idle:
            if let suggestion = model.detector.suggestion {
                Text("\(suggestion.title) is starting")
            } else {
                Text("Ready. Start a session with ⌥⌘R")
            }
        case .starting:
            Text("Starting…")
        case .live:
            Text("Live \(CallTime.stamp(session.callTime)) with \(session.playbook.name)")
        case .finishing:
            Text("Saving the session…")
        case .failed(let message):
            Text(message)
        }
        if !session.summarizing.isEmpty {
            Text(session.summarizing.count == 1 ? "Writing a summary…" : "Writing \(session.summarizing.count) summaries…")
        }
        if !session.imports.isEmpty {
            Text(session.imports.count == 1 ? "Transcribing a recording…" : "Transcribing \(session.imports.count) recordings…")
        }
    }

    @ViewBuilder
    private var controls: some View {
        let session = model.session
        if session.isLive {
            Button("Stop session") { session.stop() }
            Button("Answer what they asked") { model.answerNow() }
                .disabled(session.copilot == nil)
            Button("Ask Saaa…") { model.focusAsk() }
                .disabled(session.copilot == nil)
            Button("Look at my screen") { model.lookAtScreen() }
                .disabled(session.copilot == nil)
            Button(model.panelExpanded ? "Hide the live panel" : "Show the live panel") {
                model.panelExpanded.toggle()
            }
            Button(session.micMuted ? "Unmute my mic" : "Mute my mic") {
                session.setMicMuted(!session.micMuted)
            }
            Button("Call context…") { model.openPrep() }
            Menu("Playbook") {
                ForEach(model.playbooks.all) { playbook in
                    Toggle(playbook.name, isOn: Binding(
                        get: { session.playbook.id == playbook.id },
                        set: { if $0 { session.switchPlaybook(playbook) } }))
                }
            }
        } else if !session.isBusy {
            if model.detector.suggestion != nil {
                Button("Start this meeting") { model.startSuggested() }
            }
            Button("Start session") { model.startSession() }
            Menu("Start with") {
                ForEach(model.playbooks.all) { playbook in
                    Button(playbook.name) { model.startSession(playbook: playbook) }
                }
            }
            Button("Prepare a session…") { model.openPrep() }
            Divider()
            Button(model.codeAssist.unread > 0 ? "Code Assist (\(model.codeAssist.unread) new)" : "Code Assist") {
                model.openCodeAssist()
            }
            if model.codeAssistEnabled {
                Button("Look at my code") { model.codeLook() }
            }
        }
    }
}
