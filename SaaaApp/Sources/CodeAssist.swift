import AgentBridge
import AppKit
import CallSession
import DesignSystem
import SwiftUI
import Vision

/// Code Assist (issue #9): capture a user-selected screen region with the
/// system crosshair, read it on device, and get a hint at the chosen level,
/// optionally grounded in a real project. The screenshot itself is deleted
/// the moment its text is read — only the recognized TEXT ever reaches the
/// agent, and the pane shows exactly what was sent.

// MARK: - Region capture

/// Runs the system's interactive region picker (`screencapture -i`). The
/// user drags the region themselves (or presses Esc to cancel), which
/// satisfies both "user-selected region only" and "capture is obvious" —
/// the crosshair UI cannot be missed.
enum RegionCapture {
    static func captureInteractive() async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saaa-code-assist-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        do {
            try process.run()
        } catch {
            return nil
        }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return nil } // Esc pressed: no file
        return url
    }
}

/// On-device OCR via Vision. Nothing leaves the machine here.
enum ScreenTextReader {
    static func text(in imageURL: URL) async -> String? {
        let path = imageURL.path
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // code is not prose
            let handler = VNImageRequestHandler(url: URL(filePath: path))
            guard (try? handler.perform([request])) != nil else { return nil }
            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }
}

// MARK: - Model

@MainActor
@Observable
final class CodeAssistModel {

    static let enabledKey = "codeAssistEnabled"
    static let hintLevelKey = "codeAssistHintLevel"
    static let projectKey = "codeAssistProject"

    enum Phase: Equatable {
        case idle
        case capturing
        case reading
        case thinking
        case answered(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Exactly what was sent to the agent — full transparency.
    private(set) var capturedText = ""
    var question = ""

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    var hintLevel: HintLevel {
        get {
            HintLevel(rawValue: UserDefaults.standard.string(forKey: Self.hintLevelKey) ?? "")
                ?? .approach
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.hintLevelKey) }
    }

    var projectPath: String {
        get { UserDefaults.standard.string(forKey: Self.projectKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.projectKey) }
    }

    /// The whole flow: crosshair -> OCR -> delete screenshot -> dispatch.
    func captureAndAsk() {
        guard Self.isEnabled else {
            phase = .failed("Enable Code Assist in Settings first.")
            return
        }
        guard phase != .capturing, phase != .reading, phase != .thinking else { return }
        phase = .capturing
        Task {
            guard let shot = await RegionCapture.captureInteractive() else {
                phase = .idle // cancelled with Esc, or permission missing
                return
            }
            phase = .reading
            let text = await ScreenTextReader.text(in: shot)
            try? FileManager.default.removeItem(at: shot)
            guard let text else {
                phase = .failed("No readable text in that region. If this is the first use, grant Screen Recording in System Settings and try again.")
                return
            }
            capturedText = text
            await dispatch()
        }
    }

    /// Re-asks about the SAME captured text (level or question changed).
    func askAgain() {
        guard !capturedText.isEmpty else { return }
        Task { await dispatch() }
    }

    private func dispatch() async {
        phase = .thinking
        let answer = await CodeAssistService().answer(
            screenText: capturedText,
            hintLevel: hintLevel,
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            codebaseFolder: projectPath.isEmpty ? nil : projectPath)
        phase = answer.map { .answered($0) }
            ?? .failed("No answer. Check your agent in Settings.")
    }
}

// MARK: - Hub pane

struct CodeAssistPane: View {
    let controller: CallController
    let model: CodeAssistModel

    @Environment(\.saaa) private var saaa
    @AppStorage(CodeAssistModel.enabledKey) private var enabled = false
    @State private var knownProjects: [String] = []
    @State private var capturedShown = false

    var body: some View {
        ScrollView {
            PaneColumn {
                VStack(alignment: .leading, spacing: Space.lg) {
                    PaneHeader(
                        title: "Code Assist",
                        subtitle: "Capture a screen region and ask your agent.",
                        help: "The crosshair screenshot is read on this Mac and deleted immediately; only its text goes to your agent. For your own development, debugging, and practice.")

                    if enabled {
                        controls
                        outcome
                    } else {
                        PaneEmptyState(
                            headline: "Code Assist is off",
                            guidance: "Turn it on in Settings, then capture and it lands here.",
                            hotkey: "⇧⌥⌘C")
                    }
                    Spacer(minLength: 0)
                }
                .padding(Space.xxl)
            }
        }
        .onAppear { knownProjects = controller.knownProjectPaths() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Button {
                    model.captureAndAsk()
                } label: {
                    Label("Capture region", systemImage: "viewfinder")
                        .font(SaaaFont.bodyEmphasis)
                        .foregroundStyle(saaa.textOnAccent)
                        .padding(.horizontal, Space.lg)
                        .frame(height: Size.controlLg)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.tideFill))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                Text("⇧⌥⌘C")
                    .font(SaaaFont.monoBody)
                    .foregroundStyle(saaa.textTertiary)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.hintLevel },
                    set: { model.hintLevel = $0 })) {
                    ForEach(HintLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                HelpDot("Nudge asks one Socratic question. Approach outlines the idea. Full works it through. A codebase grounds the help in your real files with read-only tools.")
            }
            HStack(spacing: Space.md) {
                TextField("Question (optional)", text: Binding(
                    get: { model.question },
                    set: { model.question = $0 }))
                    .textFieldStyle(.plain)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                    .padding(.horizontal, Space.md)
                    .frame(height: Size.controlLg)
                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceInset))
                Picker("", selection: Binding(
                    get: { model.projectPath },
                    set: { model.projectPath = $0 })) {
                    Text("No codebase").tag("")
                    ForEach(knownProjects, id: \.self) { path in
                        Text(URL(filePath: path).lastPathComponent).tag(path)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var busy: Bool {
        switch model.phase {
        case .capturing, .reading, .thinking: true
        default: false
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .capturing:
            Text("Drag a region, or press Esc to cancel…")
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textSecondary)
        case .reading:
            Text("Reading the region on this Mac…")
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textSecondary)
        case .thinking:
            Text("Thinking…")
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textSecondary)
        case .failed(let message):
            Text(message)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.dangerText)
                .fixedSize(horizontal: false, vertical: true)
        case .answered(let answer):
            VStack(alignment: .leading, spacing: Space.md) {
                Text(answer)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.lg).fill(saaa.surfaceRaised))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .strokeBorder(saaa.borderHairline, lineWidth: 1))
                HStack(spacing: Space.lg) {
                    Button("Ask again") { model.askAgain() }
                        .buttonStyle(.plain)
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.tideText)
                    Button(capturedShown ? "Hide what was sent" : "Show what was sent") {
                        capturedShown.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.tideText)
                }
                if capturedShown {
                    Text(model.capturedText)
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceInset))
                }
            }
        }
    }
}
