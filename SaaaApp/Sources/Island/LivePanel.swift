import CallSession
import Copilot
import Core
import DesignSystem
import Persistence
import SwiftUI
import Transcription

/// The live copilot: a dark Liquid Glass panel under the island. Answer
/// card first, live transcript and notes one tab away, quick actions and
/// the Ask field always in reach.
struct LivePanel: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ScreenPrivacyPolicy.enabledKey) private var screenPrivacy = false
    @AppStorage(SaaaSettings.consentReminderKey) private var consentReminder = true
    @State private var tab: Tab = .copilot
    @State private var askText = ""
    @State private var selectedID: UUID?
    @State private var copiedID: UUID?
    @FocusState private var askFocused: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case copilot = "Copilot"
        case transcript = "Transcript"
        case notes = "Notes"
        var id: String { rawValue }
    }

    private var session: SessionController { model.session }
    private var copilot: CopilotEngine? { session.copilot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.lg)
                .padding(.top, 14)
                .padding(.bottom, Space.sm)
            if showsConsentBanner {
                consentBanner
                    .padding(.horizontal, Space.md)
                    .padding(.bottom, Space.sm)
            }
            if let note = statusNote {
                noteRow(note)
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
            }
            tabRow
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.sm)
            Group {
                switch tab {
                case .copilot: copilotTab
                case .transcript: transcriptTab
                case .notes: notesTab
                }
            }
            .frame(height: 268, alignment: .top)
            if let copilot {
                quickActions(copilot)
            }
            askBar
        }
        .frame(width: Size.Island.panelWidth)
        .saaaGlass(cornerRadius: Radius.panel)
        .onChange(of: model.askFocusToken) { _, _ in
            tab = .copilot
            askFocused = true
        }
        .onChange(of: copilot?.thread.count) { _, _ in
            selectedID = nil
        }
        .onExitCommand {
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) { model.panelExpanded = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            Lamp(.recording)
            Text(CallTime.stamp(session.callTime))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
            playbookMenu
            if let app = session.appName {
                Text("· \(app)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            TalkRatioBar(me: session.transcript.talkTime.me, them: session.transcript.talkTime.them)
            iconButton("square.and.pencil", help: "Session context") { model.openPrep() }
            iconButton(screenPrivacy ? "eye.slash.fill" : "eye", help: screenPrivacy ? "Hidden from screen sharing. Click to show." : "Hide Saaa from screen sharing", active: screenPrivacy) {
                screenPrivacy.toggle()
            }
            iconButton(session.micMuted ? "mic.slash.fill" : "mic", help: session.micMuted ? "Unmute your side" : "Mute your side", active: session.micMuted) {
                session.setMicMuted(!session.micMuted)
            }
            Button {
                session.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(saaa.emberLamp))
            }
            .buttonStyle(.plain)
            .help("Stop and save (⌥⌘R)")
            .accessibilityLabel("Stop recording")
            iconButton("chevron.up", help: "Collapse (Esc)") {
                withAnimation(Motion.collapse(reduceMotion: reduceMotion)) { model.panelExpanded = false }
            }
        }
    }

    private var playbookMenu: some View {
        Menu {
            ForEach(model.playbooks.all) { playbook in
                Button {
                    session.switchPlaybook(playbook)
                } label: {
                    Label(playbook.name, systemImage: playbook.symbol)
                }
            }
        } label: {
            HStack(spacing: 3) {
                PlaybookBadge(session.playbook, compact: true)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch playbook")
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? saaa.tideEmphasis : Color.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Consent and status

    private var showsConsentBanner: Bool {
        consentReminder && !model.consentHandled && session.callTime < 900
    }

    private var consentBanner: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(saaa.emberText)
            Text("Let everyone know Saaa is taking notes.")
                .font(.system(size: 12))
            Spacer()
            Button("Copy a line") {
                Exporting.copy(SaaaSettings.disclosureLine)
                model.consentHandled = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(saaa.tideEmphasis)
            Button("Done") { model.consentHandled = true }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(0.06)))
    }

    private var statusNote: String? {
        session.copilotOffReason ?? session.transcriptionNote ?? copilot?.notice ?? echoTip
    }

    /// On speakers the mic hears the other side. Saaa filters it out, and
    /// once that's happening a lot it's worth a tip.
    private var echoTip: String? {
        session.onSpeakers || session.transcript.echoCount >= 3
            ? "You're on speakers, so Saaa filters their voice out of your mic. Headphones give a cleaner transcript."
            : nil
    }

    private func noteRow(_ note: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(note)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            if session.copilotOffReason != nil {
                Button("Add key") { model.openHub(.settings) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(saaa.tideEmphasis)
            }
        }
        .foregroundStyle(saaa.emberText)
    }

    // MARK: - Tabs

    private var tabRow: some View {
        HStack {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
            Spacer()
            if tab == .notes, let copilot {
                Button {
                    copilot.refreshNotes()
                } label: {
                    if copilot.isUpdatingNotes {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(copilot.isUpdatingNotes)
            }
        }
    }

    // MARK: - Copilot tab

    private var copilotTab: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let pending = copilot?.pendingQuestion {
                pendingChip(pending)
            }
            if let exchange = displayedExchange {
                answerCard(exchange)
            } else {
                emptyCopilot
            }
        }
        .padding(.horizontal, Space.md)
    }

    private var displayedExchange: CopilotExchange? {
        guard let thread = copilot?.thread, !thread.isEmpty else { return nil }
        if let selectedID, let match = thread.first(where: { $0.id == selectedID }) { return match }
        return thread.last
    }

    private func pendingChip(_ question: CopilotEngine.DetectedQuestion) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "questionmark.bubble.fill").foregroundStyle(saaa.tideEmphasis)
            VStack(alignment: .leading, spacing: 1) {
                Text("They asked").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(question.text).font(.system(size: 12)).lineLimit(1)
            }
            Spacer()
            Button("Answer") { copilot?.answerPending() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(saaa.tideFill))
                .foregroundStyle(.white)
            Button {
                copilot?.dismissPending()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss question")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(saaa.tideFill.opacity(0.18)))
    }

    private func answerCard(_ exchange: CopilotExchange) -> some View {
        let streaming = copilot?.streamingID == exchange.id
        let thread = copilot?.thread ?? []
        let index = thread.firstIndex { $0.id == exchange.id } ?? 0
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text(exchange.title).engravedLabelStyle().foregroundStyle(saaa.tideEmphasis).lineLimit(1)
                if let prompt = exchange.prompt, exchange.kind != .ask {
                    Text("“\(prompt)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let ttft = exchange.firstTokenSeconds {
                    Text(String(format: "%.1fs", ttft))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("Time to first word")
                }
                if thread.count > 1 {
                    HStack(spacing: 2) {
                        navButton("chevron.left", disabled: index == 0) { selectedID = thread[max(0, index - 1)].id }
                        Text("\(index + 1)/\(thread.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        navButton("chevron.right", disabled: index >= thread.count - 1) {
                            selectedID = index + 1 >= thread.count - 1 ? nil : thread[index + 1].id
                        }
                    }
                }
            }
            ScrollView {
                if let failure = exchange.failure, exchange.response.isEmpty {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(saaa.dangerText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if exchange.response.isEmpty, streaming {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    StreamingText(exchange.response, isStreaming: streaming, font: .system(size: 14.5))
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            HStack(spacing: Space.md) {
                ForEach(PromptComposer.Refinement.allCases, id: \.self) { refinement in
                    Button(refinement.title) { copilot?.refine(exchange.id, refinement) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .disabled(streaming || exchange.response.isEmpty)
                }
                Spacer()
                if streaming {
                    Button("Stop") { copilot?.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                iconButton(copiedID == exchange.id ? "checkmark" : "doc.on.doc", help: "Copy") {
                    Exporting.copy(exchange.response)
                    copiedID = exchange.id
                }
                iconButton(exchange.isPinned ? "pin.fill" : "pin", help: exchange.isPinned ? "Unpin" : "Pin", active: exchange.isPinned) {
                    copilot?.togglePin(exchange.id)
                }
            }
        }
        .padding(Space.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.black.opacity(0.28)))
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.secondary)
        .disabled(disabled)
    }

    private var emptyCopilot: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(saaa.tideEmphasis)
            Text(copilot == nil ? "Listening. Live answers are off." : "Ask anything, or tap an action.")
                .font(.system(size: 15, weight: .semibold))
            Text(copilot == nil
                 ? "The transcript and notes still work. Add a Claude API key in Settings for live answers."
                 : "Answers stream in about a second. When they ask you something, ⌥⌘A answers it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, Space.sm)
    }

    // MARK: - Transcript tab

    private var transcriptTab: some View {
        let lines = Array(session.transcript.lines.suffix(250))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if lines.isEmpty {
                        Text("Words appear here as people talk.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, Space.lg)
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(line.lane.label)
                                .engravedLabelStyle()
                                .foregroundStyle(line.lane == .me ? saaa.tideEmphasis : Color.secondary)
                                .frame(width: 38, alignment: .leading)
                            Text(line.text)
                                .font(.system(size: 13))
                                .foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
                                .italic(!line.isFinal)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
                .padding(.horizontal, Space.lg)
            }
            .onChange(of: session.transcript.revision) { _, _ in
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
        }
    }

    // MARK: - Notes tab

    private var notesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                if let notes = copilot?.notes, !notes.isEmpty {
                    notesSection("Key points", notes.keyPoints)
                    notesSection("Decisions", notes.decisions)
                    notesSection("Action items", notes.actionItems)
                    notesSection("Open questions", notes.openQuestions)
                    Text("Updated \(notes.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(copilot == nil ? "Notes need a Claude API key." : "Notes build up as people talk; Saaa refreshes them every minute or so.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, Space.lg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.lg)
        }
    }

    @ViewBuilder
    private func notesSection(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(saaa.tideEmphasis)
                        Text(item).font(.system(size: 13)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Actions and Ask

    private func quickActions(_ copilot: CopilotEngine) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) {
                ForEach(Array(session.playbook.quickActions.enumerated()), id: \.element.id) { index, action in
                    ActionChip(
                        action.title, symbol: action.symbol,
                        hint: index < 4 ? "⌘\(index + 1)" : nil,
                        prominent: index == 0,
                        isBusy: copilot.isStreaming && copilot.latest?.actionID == action.id
                    ) {
                        copilot.run(action)
                        tab = .copilot
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(min(index + 1, 9))")), modifiers: .command)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
        .scrollIndicators(.never)
    }

    private var askBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(saaa.tideEmphasis)
            TextField("Ask anything about this call…", text: $askText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($askFocused)
                .onSubmit(submit)
                .disabled(copilot == nil)
            if !askFocused, askText.isEmpty {
                KeyCap("⌥⌘K")
            }
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(askText.isEmpty ? Color.secondary : saaa.tideEmphasis)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(copilot == nil)
            .help(askText.isEmpty ? "Answer what they just asked (⌘↩)" : "Ask (↩)")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 40)
        .background(Capsule().fill(.white.opacity(0.08)))
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.md)
    }

    private func submit() {
        let text = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        askText = ""
        tab = .copilot
        if text.isEmpty {
            model.answerNow()
        } else {
            copilot?.ask(text)
        }
    }
}
