import AnthropicKit
import AppKit
import CallSession
import Copilot
import Core
import DesignSystem
import Persistence
import SwiftUI
import Transcription

/// Settings: Claude, models, transcription, recording, permissions, the
/// island, Screen Privacy and data. Grouped like System Settings.
struct SettingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            ClaudeSection(model: model)
            ModelsSection(model: model)
            TranscriptionSection()
            RecordingSection()
            PermissionsSection()
            IslandSection()
            CodeAssistSection(model: model)
            ScreenPrivacySection()
            DataSection(model: model)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            PaneHeader("Settings", subtitle: "Audio stays on this Mac. Transcript text goes to Claude through your Saaa server only when the copilot works.")
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Claude

private struct ClaudeSection: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa
    @State private var setup = ClaudeConnectionSetup()
    @State private var confirmDelete = false

    var body: some View {
        Section {
            if let connection = setup.connection {
                LabeledContent("Claude") {
                    HStack(spacing: Space.sm) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(connection.keyHint)
                                .font(.system(size: 12, design: .monospaced))
                            Text("on \(connection.server.host() ?? connection.server.absoluteString)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.disabled)
                        Button("Test") { setup.test() }
                            .disabled(setup.isChecking)
                        Button("Disconnect") {
                            setup.disconnect { model.refreshKeyState() }
                        }
                    }
                }
            }
            LabeledContent(setup.isConnected ? "Replace key" : "API key") {
                HStack(spacing: Space.sm) {
                    SecureField("sk-ant-…", text: $setup.entry)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                        .onSubmit(connect)
                    Button(setup.isConnected ? "Replace" : "Connect", action: connect)
                        .disabled(!setup.canSubmit)
                }
            }
            switch setup.state {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Checking with your Saaa server…").foregroundStyle(.secondary)
                }
            case .verified(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(saaa.successText)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(saaa.dangerText)
            }
            LabeledContent("Server") {
                TextField("https://", text: $setup.serverText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 300)
                    .disabled(setup.isConnected)
                    .help(setup.isConnected ? "Disconnect to use a different server." : "The Saaa server that keeps your key.")
            }
            if setup.isConnected {
                LabeledContent("Remove") {
                    Button("Delete key from server…", role: .destructive) { confirmDelete = true }
                        .disabled(setup.isChecking)
                }
            }
            if let url = URL(string: "https://console.anthropic.com/settings/keys") {
                Link("Get an API key from the Claude Console", destination: url)
                    .font(.system(size: 12))
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Bring your own key. It's sent once to your Saaa server, which checks it with Anthropic, encrypts it and keeps it there. This Mac stores only an access token, so there are no Keychain prompts. Requests pass through the server on their way to Anthropic; the server doesn't keep what's in them.")
        }
        .confirmationDialog("Delete your key from the server?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete key", role: .destructive) {
                setup.deleteFromServer { model.refreshKeyState() }
            }
        } message: {
            Text("Every device using this key is signed out. You can connect again any time.")
        }
    }

    private func connect() {
        guard setup.canSubmit else { return }
        setup.connect { model.refreshKeyState() }
    }
}

// MARK: - Models

private struct ModelsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            ForEach(ModelRole.allCases, id: \.self) { role in
                ModelRoleRow(role: role)
            }
            LabeledContent("Spent this month") {
                Text(UsageLedger.format(model.monthlyCost))
                    .font(.system(size: 12, design: .monospaced))
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Haiku is the fastest and cheapest, which suits live help. Sonnet writes richer summaries. Spending is estimated from token counts at published prices.")
        }
    }
}

private struct ModelRoleRow: View {
    let role: ModelRole

    @AppStorage private var stored: String
    @State private var showsCustom = false

    private static let customTag = "custom"

    init(role: ModelRole) {
        self.role = role
        _stored = AppStorage(wrappedValue: "", role.defaultsKey)
    }

    private var isCustomStored: Bool {
        !stored.isEmpty && ModelCatalog.model(id: stored) == nil
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if showsCustom || isCustomStored { return Self.customTag }
                return stored.isEmpty ? role.defaultModel.id : stored
            },
            set: { value in
                if value == Self.customTag {
                    showsCustom = true
                } else {
                    showsCustom = false
                    stored = value == role.defaultModel.id ? "" : value
                }
            })
    }

    var body: some View {
        Picker(role.displayName, selection: selection) {
            ForEach(ModelCatalog.all) { model in
                Text(label(for: model)).tag(model.id)
            }
            Divider()
            Text("Custom model ID").tag(Self.customTag)
        }
        if showsCustom || isCustomStored {
            LabeledContent("Model ID") {
                TextField("claude-…", text: $stored)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 260)
            }
        }
    }

    private func label(for model: ClaudeModel) -> String {
        let speed = switch model.speed {
        case .fastest: "fastest"
        case .fast: "fast"
        case .moderate: "most capable"
        }
        let suffix = model.id == role.defaultModel.id ? ", default" : ""
        return "\(model.shortName) (\(speed)\(suffix))"
    }
}

// MARK: - Transcription

private struct TranscriptionSection: View {
    @AppStorage(SaaaSettings.localeKey) private var localeID = ""
    @Environment(\.saaa) private var saaa
    @State private var speech = SpeechSetup()

    var body: some View {
        Section {
            Picker("Language", selection: $localeID) {
                Text("Automatic (\(Self.name(of: Locale.current)))").tag("")
                ForEach(speech.languages, id: \.identifier) { locale in
                    Text(Self.name(of: locale)).tag(locale.identifier)
                }
            }
            .task {
                await speech.loadLanguages()
                await speech.refresh()
            }
            .onChange(of: localeID) {
                Task { await speech.refresh() }
            }
            LabeledContent("Speech model") {
                speechStatus
            }
            if let failure = speech.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.dangerText)
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text("Apple's on-device speech model writes the transcript. It downloads once from Apple and runs offline. Audio never leaves this Mac.")
        }
    }

    @ViewBuilder
    private var speechStatus: some View {
        if let progress = speech.progress {
            HStack(spacing: Space.sm) {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            switch speech.status {
            case .installed:
                Label("On this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(saaa.successText)
            case .needsDownload:
                Button("Download") { speech.install() }
            case .downloading:
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Downloading").foregroundStyle(.secondary)
                }
            case .unsupported:
                Text("Not available for this language")
                    .foregroundStyle(saaa.dangerText)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

// MARK: - Recording

private struct RecordingSection: View {
    @AppStorage(SaaaSettings.autoSummaryKey) private var autoSummary = true
    @AppStorage(SaaaSettings.keepAudioKey) private var keepAudio = false
    @AppStorage(SaaaSettings.meetingDetectionKey) private var meetingDetection = true
    @AppStorage(SaaaSettings.consentReminderKey) private var consentReminder = true
    @State private var copied = false

    var body: some View {
        Section {
            Toggle(isOn: $autoSummary) {
                Text("Write the summary when a call ends")
                Text("Uses Claude. You can always write one later from the session.")
            }
            Toggle(isOn: $meetingDetection) {
                Text("Suggest a session when a meeting starts")
                Text("Watches your calendar and call apps on this Mac. Saaa never starts recording by itself.")
            }
            Toggle(isOn: $consentReminder) {
                Text("Remind me to tell people")
                Text("A reminder at the start of each session, with a line you can paste into the chat.")
            }
            LabeledContent("Disclosure line") {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SaaaSettings.disclosureLine, forType: .string)
                    copied = true
                }
            }
            Toggle(isOn: $keepAudio) {
                Text("Keep audio recordings")
                Text("Recordings stay in the session folder as WAV files, not encrypted. When off, they're deleted once the transcript is saved.")
            }
        } header: {
            Text("Recording")
        }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @Environment(\.saaa) private var saaa
    @State private var permissions = PermissionCenter()

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: Space.sm) {
                    status(permissions.microphone)
                    switch permissions.microphone {
                    case .notAsked: Button("Allow") { permissions.requestMicrophone() }
                    case .denied: Button("Open Settings") { permissions.openMicrophoneSettings() }
                    default: EmptyView()
                    }
                }
            } label: {
                Text("Microphone")
                Text("Your side of the call.")
            }
            LabeledContent {
                HStack(spacing: Space.sm) {
                    status(permissions.systemAudio)
                    Button("Check") { permissions.verifySystemAudio() }
                        .disabled(permissions.systemAudio == .checking)
                    if permissions.systemAudio == .denied {
                        Button("Open Settings") { permissions.openSystemAudioSettings() }
                    }
                }
            } label: {
                Text("System audio")
                Text("Their side, from your call app. Listed under Screen & System Audio Recording.")
            }
            LabeledContent {
                HStack(spacing: Space.sm) {
                    status(permissions.calendar)
                    switch permissions.calendar {
                    case .notAsked: Button("Allow") { permissions.requestCalendar() }
                    case .denied: Button("Open Settings") { permissions.openCalendarSettings() }
                    default: EmptyView()
                    }
                }
            } label: {
                Text("Calendar")
                Text("Optional. Suggests sessions and fills in who's on the call.")
            }
        } header: {
            Text("Permissions")
        }
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder
    private func status(_ status: PermissionCenter.Status) -> some View {
        switch status {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(saaa.successText)
        case .denied:
            Label("Not allowed", systemImage: "xmark.circle.fill")
                .foregroundStyle(saaa.dangerText)
        case .checking:
            ProgressView().controlSize(.small)
        case .notAsked:
            Text("Not asked yet").foregroundStyle(.secondary)
        case .unverified:
            Text("Not checked").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Island

private struct IslandSection: View {
    @AppStorage(SaaaSettings.showIslandKey) private var showIsland = true
    @AppStorage(SaaaSettings.freezeMetersKey) private var freezeMeters = false

    var body: some View {
        Section {
            Toggle(isOn: $showIsland) {
                Text("Show the island")
                Text("The black bar under the notch: status, timer and the live panel.")
            }
            Toggle(isOn: $freezeMeters) {
                Text("Still level meters")
                Text("Shows levels without movement.")
            }
            LabeledContent("Start or stop a session") { KeyCap("⌥⌘R") }
            LabeledContent("Answer what they just asked") { KeyCap("⌥⌘A") }
            LabeledContent("Ask Saaa anything") { KeyCap("⌥⌘K") }
            LabeledContent("Look at your screen") { KeyCap("⌥⌘L") }
            LabeledContent("Quick actions, in the live panel") { KeyCap("⌘1 to ⌘4") }
        } header: {
            Text("Island and shortcuts")
        }
    }
}

// MARK: - Code Assist

private struct CodeAssistSection: View {
    @Bindable var model: AppModel

    @State private var available: [(bundleID: String, name: String)] = []

    private var engine: CodeAssistEngine { model.codeAssist }

    var body: some View {
        Section {
            Toggle(isOn: $model.codeAssistEnabled) {
                Text("Code Assist outside calls")
                Text("⌥⌘L reads the window in front and helps with errors, code and coding problems. While this is on, Finder and Safari lose their own ⌥⌘L.")
            }
            Toggle(isOn: Binding(get: { engine.watchEnabled }, set: { engine.watchEnabled = $0 })) {
                Text("Watch my code")
                Text("In the apps below, Saaa reads the window after you pause typing and flags new errors. Only errors reach Claude on their own, at most once a minute. Paused during calls.")
            }
            if engine.watchEnabled {
                ForEach(available, id: \.bundleID) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { engine.watchedApps.contains(app.bundleID) },
                        set: { on in
                            if on { engine.watchedApps.insert(app.bundleID) } else { engine.watchedApps.remove(app.bundleID) }
                        }))
                }
                LabeledContent("Another app") {
                    Button("Add an app…") { addApp() }
                }
            }
            Toggle(isOn: Binding(get: { engine.learningMode }, set: { engine.learningMode = $0 })) {
                Text("Learning mode")
                Text("Coding problems start with a nudge instead of the approach.")
            }
            LabeledContent {
                Text(model.editorConnections.isEmpty ? "Not connected" : model.editorConnections.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("Editor extension")
                Text("With the Saaa extension, VS Code, Cursor and Windsurf send their exact text, errors and last failed command instead of Saaa reading the screen.")
            }
            LabeledContent("Code Assist panel") {
                Button("Open") { model.openCodeAssist() }
            }
        } header: {
            Text("Code Assist")
        } footer: {
            Text("Code Assist reads windows on this Mac and sends only their text, after hiding secrets such as keys and passwords. Hints stay in memory until Saaa quits. On a call, and on pages that look like an assessment or a test, coding problems get the approach, never solution code.")
        }
        .onAppear(perform: refresh)
        .onChange(of: engine.watchedApps) { _, _ in refresh() }
    }

    /// Known editors that are installed, plus any app the user added.
    private func refresh() {
        let workspace = NSWorkspace.shared
        var apps = CodeAssistSettings.knownApps.filter { workspace.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
        let known = Set(CodeAssistSettings.knownApps.map(\.bundleID))
        for bundleID in engine.watchedApps.sorted() where !known.contains(bundleID) {
            let name = workspace.urlForApplication(withBundleIdentifier: bundleID)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
            apps.append((bundleID, name))
        }
        available = apps
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.message = "Choose an app for Watch to read."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        engine.watchedApps.insert(bundleID)
    }
}

// MARK: - Screen Privacy

private struct ScreenPrivacySection: View {
    @AppStorage(ScreenPrivacyPolicy.enabledKey) private var enabled = false
    @AppStorage(ScreenPrivacyPolicy.scopeKey) private var scope = ScreenPrivacyScope.allWindows.rawValue

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Text("Hide Saaa from screen sharing")
                Text("Leaves Saaa's windows out of screenshots, recordings and shared screens, so your notes stay yours.")
            }
            if enabled {
                Picker("Hide", selection: $scope) {
                    Text("All Saaa windows").tag(ScreenPrivacyScope.allWindows.rawValue)
                    Text("Only windows with call content").tag(ScreenPrivacyScope.callContent.rawValue)
                }
            }
        } header: {
            Text("Screen Privacy")
        } footer: {
            Text("A standing setting, not a reaction to a share starting. It can't hide anything from a camera, and it doesn't replace telling people you use Saaa.")
        }
    }
}

// MARK: - Data

private struct DataSection: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa
    @State private var confirmDelete = false

    var body: some View {
        Section {
            LabeledContent("Sessions") {
                HStack(spacing: Space.sm) {
                    Text("\(model.sessions.count)")
                        .font(.system(size: 12, design: .monospaced))
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.library.root])
                    }
                }
            }
            LabeledContent("Encryption") {
                if model.encryptionHealthy {
                    Label("Sealed with a key in Saaa's folder", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Encryption key unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(saaa.dangerText)
                }
            }
            LabeledContent("Setup") {
                Button("Run setup again") { model.runOnboardingAction() }
            }
            LabeledContent("Delete") {
                Button("Delete all sessions…", role: .destructive) { confirmDelete = true }
                    .disabled(model.sessions.isEmpty || model.session.isBusy)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Transcripts, notes and summaries are encrypted on this Mac. Nothing is uploaded except the text Claude needs to help.")
        }
        .confirmationDialog("Delete all \(model.sessions.count) sessions?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all sessions", role: .destructive) { model.deleteAllSessions() }
        } message: {
            Text("Transcripts, notes, summaries and any kept audio are removed from this Mac. This can't be undone.")
        }
    }
}
