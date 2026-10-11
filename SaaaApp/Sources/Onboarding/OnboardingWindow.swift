import AppKit
import CallSession
import Core
import DesignSystem
import SwiftUI
import Transcription

/// First run: what Saaa does with your audio, the permissions it needs,
/// Claude, the speech model, and a default playbook. Every step can be
/// skipped and the whole flow runs again from Settings.
@MainActor
final class OnboardingPresenter {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show(onFinish: @escaping @MainActor () -> Void) {
        if let window, window.isVisible {
            AppPresence.adopt(window)
            WindowFront.present(window)
            return
        }
        let view = OnboardingView(app: model) { [weak self] in
            UserDefaults.standard.set(true, forKey: SaaaSettings.onboardingCompleteKey)
            self?.window?.close()
            self?.window = nil
            onFinish()
        }
        .saaaThemed()
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Saaa"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 660, height: 660))
        window.isReleasedWhenClosed = false
        WindowChrome.applySeamless(to: window)
        window.center()
        ScreenPrivacy.shared.register(window, as: .onboarding)
        self.window = window
        AppPresence.adopt(window)
        WindowFront.present(window)
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, claude, speech, playbook
}

private struct OnboardingView: View {
    let app: AppModel
    let onFinish: @MainActor () -> Void

    @Environment(\.saaa) private var saaa
    @State private var step: OnboardingStep = .welcome
    @State private var permissions = PermissionCenter()
    @State private var key = ClaudeConnectionSetup()
    @State private var speech = SpeechSetup()
    @State private var defaultID = Playbook.generalID
    @AppStorage(SaaaSettings.consentReminderKey) private var consentReminder = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Space.xxl)
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissionsStep
                case .claude: claudeStep
                case .speech: speechStep
                case .playbook: playbookStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity.combined(with: .offset(x: -24))))
            .id(step)
            footer
        }
        .padding(.horizontal, 44)
        .padding(.top, 48)
        .padding(.bottom, 28)
        .frame(width: 660, height: 660)
        .background(background)
        .animation(Motion.standard, value: step)
        .onAppear {
            permissions.refresh()
            defaultID = app.playbooks.defaultID
        }
        .task { await speech.refresh() }
    }

    private var background: some View {
        ZStack {
            saaa.surfaceBase
            RadialGradient(
                colors: [saaa.tideFill.opacity(0.20), .clear],
                center: .topLeading, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Space.md) {
            BrandMark(size: 20)
            Text("Saaa")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? saaa.tideFill : saaa.surfaceInset)
                        .frame(width: item == step ? 22 : 8, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            if step != .welcome {
                Button("Back") { move(-1) }
                    .buttonStyle(.glass)
            }
            Spacer()
            if let skip = skipTitle {
                Button(skip) { move(1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button(primaryTitle, action: advance)
                .buttonStyle(.glassProminent)
                .tint(saaa.tideFill)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
        .padding(.top, Space.lg)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get started"
        case .playbook: "Start using Saaa"
        default: "Continue"
        }
    }

    private var primaryDisabled: Bool {
        step == .claude && key.isChecking
    }

    private var skipTitle: String? {
        switch step {
        case .claude where !key.isConnected: "Set up later"
        case .speech where speech.status != .installed && speech.progress == nil: "Later"
        default: nil
        }
    }

    private func move(_ offset: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        step = next
    }

    private func advance() {
        switch step {
        case .claude where !key.isConnected && key.canSubmit:
            key.connect { [app] in
                app.refreshKeyState()
                step = .speech
            }
        case .playbook:
            app.setDefaultPlaybook(defaultID)
            app.refreshKeyState()
            onFinish()
        default:
            move(1)
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("A copilot for every call")
                    .font(.system(size: 32, weight: .bold))
                Text("Saaa hears both sides of your calls on this Mac, keeps a live transcript, and helps while you talk: answers, what to say next, questions worth asking. Afterwards you get a summary you can ask anything.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.lg) {
                FactRow(symbol: "waveform", title: "Audio stays on this Mac", detail: "Apple's on-device speech model writes the transcript.")
                FactRow(symbol: "sparkles", title: "Only text goes to Claude", detail: "When the copilot helps, transcript text goes to Claude through your Saaa server, using your own API key.")
                FactRow(symbol: "lock.fill", title: "Everything saved is encrypted", detail: "Sessions are sealed with AES-256 on this Mac.")
                FactRow(symbol: "person.2.wave.2.fill", title: "You tell people", detail: "Saaa reminds you to let others know, with a line you can paste into the chat.")
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepTitle(
                "Let Saaa hear the call",
                detail: "Your microphone for your side, system audio for theirs. Calendar is optional.")
            VStack(spacing: Space.md) {
                PermissionCard(
                    symbol: "mic.fill", title: "Microphone", detail: "Your side of the call.",
                    status: permissions.microphone
                ) {
                    switch permissions.microphone {
                    case .notAsked:
                        Button("Allow") { permissions.requestMicrophone() }.buttonStyle(.glass)
                    case .denied:
                        Button("Open Settings") { permissions.openMicrophoneSettings() }.buttonStyle(.glass)
                    default:
                        EmptyView()
                    }
                }
                PermissionCard(
                    symbol: "speaker.wave.2.fill", title: "System audio",
                    detail: permissions.systemAudio == .denied
                        ? "Open Settings, find Screen & System Audio Recording, turn Saaa on under System Audio Recording Only, then check again."
                        : "Their side, from your call app. Check makes macOS ask for it.",
                    status: permissions.systemAudio
                ) {
                    HStack(spacing: Space.sm) {
                        if permissions.systemAudio == .denied {
                            Button("Open Settings") { permissions.openSystemAudioSettings() }.buttonStyle(.glass)
                        }
                        if permissions.systemAudio != .granted {
                            Button("Check") { permissions.verifySystemAudio() }
                                .buttonStyle(.glass)
                                .disabled(permissions.systemAudio == .checking || permissions.microphone != .granted)
                        }
                    }
                }
                PermissionCard(
                    symbol: "calendar", title: "Calendar", detail: "Optional. Suggests a session when a meeting starts and fills in who's on it.",
                    status: permissions.calendar
                ) {
                    switch permissions.calendar {
                    case .notAsked:
                        Button("Allow") { permissions.requestCalendar() }.buttonStyle(.glass)
                    case .denied:
                        Button("Open Settings") { permissions.openCalendarSettings() }.buttonStyle(.glass)
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var claudeStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepTitle(
                "Connect Claude",
                detail: "Live help, notes, summaries and Ask this call run on Claude with your own API key. Without one, Saaa still records and transcribes.")
            VStack(alignment: .leading, spacing: Space.md) {
                if let connection = key.connection, key.entry.isEmpty {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(saaa.successText)
                        Text(connection.keyHint).font(.system(size: 13, design: .monospaced))
                        Text("on \(key.serverHost)").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Test") { key.test() }
                            .buttonStyle(.glass)
                            .disabled(key.isChecking)
                    }
                }
                HStack(spacing: Space.sm) {
                    SecureField(key.isConnected ? "Paste a new key to replace it" : "Paste your API key (sk-ant-…)", text: $key.entry)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit {
                            if key.canSubmit { key.connect { app.refreshKeyState() } }
                        }
                    Button(key.isConnected ? "Replace" : "Connect") { key.connect { app.refreshKeyState() } }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(!key.canSubmit)
                }
                keyStatus
                if let url = URL(string: "https://console.anthropic.com/settings/keys") {
                    Link("Get an API key from the Claude Console", destination: url)
                        .font(.system(size: 12))
                }
            }
            .saaaCard()
            FactRow(
                symbol: "lock.shield", title: "Your key stays off this Mac",
                detail: "Saaa sends it once to your Saaa server\(key.serverHost.isEmpty ? "" : " (\(key.serverHost))"), which checks it with Anthropic, encrypts it and keeps it. This Mac keeps only an access token.")
            FactRow(
                symbol: "dollarsign.circle", title: "You pay Anthropic directly",
                detail: "With the default models, most hour-long calls cost a few cents. Settings shows what you've spent this month.")
        }
    }

    @ViewBuilder
    private var keyStatus: some View {
        switch key.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Checking with your Saaa server…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .verified(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(saaa.successText)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(saaa.dangerText)
        }
    }

    private var speechStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepTitle(
                "Download the speech model",
                detail: "Transcription runs on Apple's on-device model for \(speech.languageName). It downloads once from Apple and works offline after that. You can change the language in Settings.")
            HStack(spacing: Space.lg) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(saaa.tideText)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(speech.languageName) speech model")
                        .font(.system(size: 14, weight: .semibold))
                    speechStatus
                }
                Spacer()
                if speech.status == .needsDownload, speech.progress == nil {
                    Button("Download") { speech.install() }
                        .buttonStyle(.glass)
                }
            }
            .saaaCard()
            if let failure = speech.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.dangerText)
            }
        }
    }

    @ViewBuilder
    private var speechStatus: some View {
        if let progress = speech.progress {
            HStack(spacing: Space.sm) {
                ProgressView(value: progress).frame(width: 180)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            switch speech.status {
            case .installed:
                Label("Ready on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.successText)
            case .needsDownload:
                Text("Not downloaded yet").font(.system(size: 12)).foregroundStyle(.secondary)
            case .downloading:
                Text("Downloading…").font(.system(size: 12)).foregroundStyle(.secondary)
            case .unsupported:
                Text("Not available for this language. Pick another one in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.dangerText)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var playbookStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepTitle(
                "What are most of your calls?",
                detail: "Pick a default playbook. Saaa suggests another when a meeting title matches it, and you can switch mid-call.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)], spacing: Space.md) {
                ForEach(app.playbooks.all.filter(\.isBuiltIn)) { playbook in
                    Button {
                        defaultID = playbook.id
                    } label: {
                        HStack(spacing: Space.md) {
                            PlaybookGlyph(symbol: playbook.symbol, tint: playbook.tint, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playbook.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(playbook.tagline)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Space.md)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(defaultID == playbook.id ? playbook.tint.color.opacity(0.14) : saaa.surfaceRaised))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(defaultID == playbook.id ? playbook.tint.color : saaa.borderHairline, lineWidth: defaultID == playbook.id ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(defaultID == playbook.id ? .isSelected : [])
                }
            }
            SwitchRow(
                "Remind me to tell people I'm using Saaa",
                detail: "A short reminder when a session starts, with a line you can paste into the chat.",
                isOn: $consentReminder)
        }
    }
}

// MARK: - Pieces

private struct StepTitle: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FactRow: View {
    let symbol: String
    let title: String
    let detail: String

    @Environment(\.saaa) private var saaa

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(saaa.tideText)
                .frame(width: 30, height: 30)
                .saaaGlass(in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionCard<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let status: PermissionCenter.Status
    let actions: Actions

    @Environment(\.saaa) private var saaa

    init(
        symbol: String, title: String, detail: String, status: PermissionCenter.Status,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.status = status
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(saaa.tideText)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    badge
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.md)
            actions
        }
        .saaaCard(padding: Space.md)
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(saaa.successText)
                .accessibilityLabel("Allowed")
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(saaa.dangerText)
                .accessibilityLabel("Not allowed")
        case .checking:
            ProgressView().controlSize(.mini)
        case .notAsked, .unverified:
            EmptyView()
        }
    }
}
