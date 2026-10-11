import AppKit
import CallSession
import Copilot
import Core
import DesignSystem
import SwiftUI

/// Code Assist floats over the editor without taking it over: a
/// non-activating panel, so the editor stays the app in front and Look
/// reads it, not this window.
final class CodeAssistWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "Code Assist"
        minSize = NSSize(width: 460, height: 420)
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class CodeAssistPresenter {
    private var panel: CodeAssistWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the panel without activating Saaa.
    func show() {
        model.codeAssist.markRead()
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = CodeAssistWindow()
        let hosting = NSHostingController(rootView: CodeAssistView(model: model).saaaThemed())
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 560, height: 560))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - panel.frame.height - 24))
        } else {
            panel.center()
        }
        ScreenPrivacy.shared.register(panel, as: .codeAssist)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Look, Watch hints and the ladder for coding problems.
struct CodeAssistView: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa
    @State private var askText = ""
    @State private var selectedID: UUID?
    @State private var sentShownID: UUID?
    @State private var copiedID: UUID?
    @AppStorage(LookSettings.sendImageKey) private var sendImageEnabled = false
    @FocusState private var askFocused: Bool

    private var engine: CodeAssistEngine { model.codeAssist }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            if let notice = engine.notice {
                noticeRow(notice)
            }
            if engine.isReading {
                readingRow
            }
            if let hint = displayed {
                hintCard(hint)
            } else {
                emptyState
            }
            askBar
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, 30)
        .padding(.bottom, Space.lg)
        .frame(minWidth: 460, minHeight: 420)
        .background(saaa.surfaceBase)
        .onChange(of: engine.hints.count) { _, _ in
            selectedID = nil
            engine.markRead()
        }
    }

    private var displayed: CodeHint? {
        if let selectedID, let match = engine.hints.first(where: { $0.id == selectedID }) { return match }
        return engine.latest
    }

    // MARK: - Header and status

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(saaa.tideEmphasis)
            Text("Code Assist")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: Space.sm)
            Text(engine.watchStatus.text)
                .font(.system(size: 11))
                .foregroundStyle(saaa.textSecondary)
                .lineLimit(1)
            Toggle("Watch", isOn: Binding(get: { engine.watchEnabled }, set: { engine.watchEnabled = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Read your chosen apps after you pause typing and flag new errors")
        }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            if engine.screenPermissionNeeded {
                Button("Allow") { model.openScreenRecordingSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(saaa.tideEmphasis)
            }
            Button {
                engine.dismissNotice()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(saaa.emberText)
    }

    private var readingRow: some View {
        HStack(spacing: Space.sm) {
            ProgressView().controlSize(.small)
            Text("Reading your screen on this Mac…")
                .font(.system(size: 12))
                .foregroundStyle(saaa.textSecondary)
            Spacer()
        }
    }

    // MARK: - Hints

    private func hintCard(_ hint: CodeHint) -> some View {
        let streaming = engine.streamingID == hint.id
        let hints = engine.hints
        let index = hints.firstIndex { $0.id == hint.id } ?? 0
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text(hint.snapshot.scene.label)
                    .engravedLabelStyle()
                    .foregroundStyle(saaa.tideEmphasis)
                if hint.automatic {
                    Text("From Watch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(saaa.textSecondary)
                }
                Text(hint.question.map { "“\($0)”" } ?? hint.snapshot.sourceLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(saaa.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let ttft = hint.firstTokenSeconds {
                    Text(String(format: "%.1fs", ttft))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(saaa.textTertiary)
                        .help("Time to first word")
                }
                if hints.count > 1 {
                    navButton("chevron.left", disabled: index == 0) { selectedID = hints[max(0, index - 1)].id }
                    Text("\(index + 1)/\(hints.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(saaa.textSecondary)
                    navButton("chevron.right", disabled: index >= hints.count - 1) {
                        selectedID = index + 1 >= hints.count - 1 ? nil : hints[index + 1].id
                    }
                }
            }
            if hint.snapshot.scene == .problem, hint.question == nil {
                ladder(hint)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if let failure = hint.failure, hint.response.isEmpty {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(saaa.dangerText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if hint.response.isEmpty, streaming {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.system(size: 13)).foregroundStyle(saaa.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        StreamingText(hint.response, isStreaming: streaming, font: .system(size: 13.5))
                            .textSelection(.enabled)
                    }
                    if sentShownID == hint.id {
                        SentScreenText(snapshot: hint.snapshot)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            HStack(spacing: Space.md) {
                Button(sentShownID == hint.id ? "Hide what was sent" : "What was sent") {
                    sentShownID = sentShownID == hint.id ? nil : hint.id
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(saaa.textSecondary)
                if sendImageEnabled, hint.snapshot.image == nil, engine.canSendImage {
                    Button("Send image") { engine.look(question: hint.question, withImage: true) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(saaa.textSecondary)
                        .disabled(streaming || engine.isReading)
                        .help("Look again and send one picture of the window, with secret-looking lines blacked out")
                }
                Spacer()
                if streaming {
                    Button("Stop") { engine.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(saaa.textSecondary)
                }
                Button {
                    Exporting.copy(hint.response)
                    copiedID = hint.id
                } label: {
                    Image(systemName: copiedID == hint.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(saaa.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(hint.response.isEmpty)
                .help("Copy")
                .accessibilityLabel("Copy")
            }
        }
        .padding(Space.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(saaa.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(saaa.borderHairline, lineWidth: 1))
    }

    /// Nudge, Approach, Pseudocode, Full: each asks again at that level.
    private func ladder(_ hint: CodeHint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(CodeRung.allCases, id: \.self) { rung in
                    let locked = hint.cap != nil && !rung.allowedWhenCapped
                    let current = hint.rung == rung
                    Button(rung.title) { engine.climb(hint.id, to: rung) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: current ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(current ? saaa.tideFill.opacity(0.3) : saaa.surfaceInset))
                        .foregroundStyle(locked ? saaa.textTertiary : saaa.textPrimary)
                        .disabled(locked || engine.isStreaming || current)
                        .help(locked ? (hint.cap?.reason ?? "") : "Ask again at this level")
                }
            }
            if let cap = hint.cap {
                Text(cap.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(saaa.textSecondary)
            }
        }
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? saaa.textTertiary : saaa.textSecondary)
        .disabled(disabled)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Spacer(minLength: 0)
            Image(systemName: "text.viewfinder")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(saaa.tideEmphasis)
            Text("Look at your code")
                .font(.system(size: 15, weight: .semibold))
            Text("Press Look with your editor, a terminal or a coding problem in front. Errors get a fix, code gets a review, and problems get a ladder from a nudge to a full solution.")
                .font(.system(size: 12))
                .foregroundStyle(saaa.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Saaa reads the window on this Mac and sends only its text, after hiding secrets. Nothing is saved.")
                .font(.system(size: 11))
                .foregroundStyle(saaa.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Ask

    private var askBar: some View {
        HStack(spacing: Space.sm) {
            TextField("Ask about your code…", text: $askText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($askFocused)
                .onSubmit(look)
            if askText.isEmpty, model.codeAssistEnabled {
                KeyCap("⌥⌘L")
            }
            Button(action: look) {
                Label(askText.isEmpty ? "Look" : "Ask", systemImage: "text.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(saaa.tideFill))
                    .foregroundStyle(saaa.textOnAccent)
            }
            .buttonStyle(.plain)
            .disabled(engine.isReading)
            .help("Read the window in front and answer")
        }
        .padding(.leading, Space.md)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(Capsule().fill(saaa.surfaceInset))
    }

    private func look() {
        let text = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        askText = ""
        selectedID = nil
        engine.look(question: text.isEmpty ? nil : text)
    }
}

/// Exactly the screen text that went to Claude with an answer.
struct SentScreenText: View {
    let snapshot: ScreenSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Sent to Claude")
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let image = snapshot.image, let picture = NSImage(data: image.data) {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 160, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityLabel("The picture that was sent")
            }
            Text(snapshot.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.sm)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.primary.opacity(0.05)))
        }
    }

    private var summary: String {
        var parts = [snapshot.sourceLabel]
        if snapshot.source == .editor { parts.append("exact text from the editor") }
        parts += ["\(snapshot.lineCount) lines", snapshot.scene.label.lowercased()]
        if snapshot.redactions > 0 {
            parts.append(snapshot.redactions == 1 ? "1 secret hidden" : "\(snapshot.redactions) secrets hidden")
        }
        if snapshot.truncated { parts.append("cut to fit") }
        if let image = snapshot.image {
            parts.append("1 picture, \(image.width)×\(image.height)")
            if image.maskedRegions > 0 {
                parts.append(image.maskedRegions == 1 ? "1 line blacked out" : "\(image.maskedRegions) lines blacked out")
            }
        }
        return parts.joined(separator: " · ")
    }
}
