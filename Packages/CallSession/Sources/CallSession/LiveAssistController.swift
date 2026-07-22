import AgentBridge
import AudioCapture
import Core
import Foundation
import Observation
import Persistence
import Transcription
import os

/// One entry in the per-call assist thread: the user's asks and the
/// copilot's responses accumulate for as long as the call runs, then seal
/// into the session archive with the transcript.
public struct LiveAssistExchange: Identifiable, Sendable, Equatable {
    public enum Kind: Equatable, Sendable {
        case ask(String)
        case answer(mode: AssistMode, text: String)
        case failed(String)
    }

    public let id: UUID
    public let at: Date
    public let kind: Kind

    init(_ kind: Kind) {
        id = UUID()
        at = Date()
        self.kind = kind
    }
}

/// Live Assist (issue #8): while a recording runs with the mode armed, a
/// micro-batch streamer transcribes the trailing window of both live lanes
/// every few seconds. The hotkey, the island's mode row, or a typed ask (or
/// a conservative question heuristic) dispatches the window to the agent;
/// responses accumulate in a continuous per-call thread shown in the
/// expanded island. Requires informed opt-in AND a Live Assist prompt;
/// every failure degrades quietly — a broken copilot must never touch the
/// recording itself.
@MainActor
@Observable
public final class LiveAssistController {

    public static let enabledKey = "liveAssistEnabled"
    public static let autoAnswerKey = "liveAssistAutoAnswer"
    public static let knowledgeFolderKey = "liveAssistKnowledgeFolder"

    public enum Phase: Equatable, Sendable {
        case off
        /// Streaming transcription runs; no answer in flight.
        case listening
        case thinking
        case answered(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .off
    /// Rolling Me/Them lines of the current window.
    public private(set) var windowLines: [String] = []
    /// The per-call conversation with the copilot, newest last.
    public private(set) var thread: [LiveAssistExchange] = []
    /// Which mode a in-flight dispatch belongs to (drives the drafting row).
    public private(set) var pendingMode: AssistMode?

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "LiveAssist")
    /// Window and cadence chosen so the cached large model keeps up on
    /// Apple silicon; a dedicated small streaming model is the follow-up.
    static let windowSeconds = 14.0
    static let cadenceSeconds = 7.0
    static let autoAnswerCooldown: TimeInterval = 45

    private var loop: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var micURL: URL?
    private var systemURL: URL?
    private var gate: AsyncGate?
    private var promptStore: PromptStore?
    private var attendeesProvider: @MainActor () -> [String] = { [] }
    private var transcriberProvider: (@MainActor () async throws -> WhisperTranscriber)?
    private var lastAutoAnswerAt = Date.distantPast
    private var lastAutoQuestion = ""

    public init() {}

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Armed = enabled AND a Live Assist prompt exists — required by
    /// design, so answers always carry the user's own context.
    public static func isArmed(promptStore: PromptStore?) -> Bool {
        guard isEnabled, let promptStore else { return false }
        let prompt = promptStore.text(.liveAssist, scope: .global)
            ?? promptStore.text(.liveAssist, scope: .nextCall)
        return !(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Lifecycle (driven by CallController)

    func begin(
        micURL: URL,
        systemURL: URL,
        gate: AsyncGate,
        promptStore: PromptStore?,
        attendeesProvider: @escaping @MainActor () -> [String],
        transcriberProvider: @escaping @MainActor () async throws -> WhisperTranscriber
    ) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.gate = gate
        self.promptStore = promptStore
        self.attendeesProvider = attendeesProvider
        self.transcriberProvider = transcriberProvider
        phase = .listening
        windowLines = []
        thread = []
        pendingMode = nil
        Self.log.info("live assist armed")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.cadenceSeconds))
                guard !Task.isCancelled else { return }
                await self?.refreshWindow()
            }
        }
    }

    /// Stops the streamer and WAITS for any in-flight transcription so the
    /// batch pipeline never runs the shared whisper context concurrently.
    func shutdownAndWait() async {
        loop?.cancel()
        answerTask?.cancel()
        let running = loop
        loop = nil
        answerTask = nil
        _ = await running?.value
        phase = .off
        windowLines = []
        pendingMode = nil
    }

    /// Snapshot of the thread for sealing into the session archive; taken
    /// by the controller right before shutdown.
    public func takeThread() -> [LiveAssistExchange] {
        thread
    }

    // MARK: - Streaming window

    private func refreshWindow() async {
        guard let micURL, let systemURL, let transcriberProvider else { return }
        guard let transcriber = try? await transcriberProvider() else {
            phase = .failed("Transcription model unavailable")
            return
        }
        let mic = WavTailReader.tailSamples(of: micURL, seconds: Self.windowSeconds)
        let system = WavTailReader.tailSamples(of: systemURL, seconds: Self.windowSeconds)
        guard mic != nil || system != nil else { return }

        // The queue worker may be transcribing an EARLIER call right now;
        // the shared whisper context takes one caller at a time.
        await gate?.lock()
        var lines: [(start: TimeInterval, line: String, remote: Bool, text: String)] = []
        if let mic, let result = try? await transcriber.transcribe(samples: mic) {
            for segment in result.segments where !segment.text.isEmpty {
                lines.append((segment.start, "Me: \(segment.text)", false, segment.text))
            }
        }
        if !Task.isCancelled, let system,
           let result = try? await transcriber.transcribe(samples: system) {
            for segment in result.segments where !segment.text.isEmpty {
                lines.append((segment.start, "Them: \(segment.text)", true, segment.text))
            }
        }
        await gate?.unlock()
        guard !Task.isCancelled else { return }
        lines.sort { $0.start < $1.start }
        windowLines = lines.map(\.line)

        // Conservative auto-trigger, hotkey remains primary.
        guard UserDefaults.standard.bool(forKey: Self.autoAnswerKey),
              case .listening = phase,
              let lastRemote = lines.last(where: { $0.remote })?.text,
              QuestionDetector.looksLikeQuestion(lastRemote),
              lastRemote != lastAutoQuestion,
              Date().timeIntervalSince(lastAutoAnswerAt) > Self.autoAnswerCooldown
        else { return }
        lastAutoAnswerAt = Date()
        lastAutoQuestion = lastRemote
        dispatch(question: lastRemote)
    }

    // MARK: - Answering

    /// The ⌥⌘A hotkey: answer the last thing the other side said.
    public func answerLastThing() {
        trigger(.assist)
    }

    /// The island's mode row: one tap runs the mode over the rolling window.
    public func trigger(_ mode: AssistMode) {
        guard phase != .off, phase != .thinking else { return }
        dispatch(question: nil, mode: mode)
    }

    /// A typed ask from the island's field; lands in the thread verbatim.
    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase != .off, phase != .thinking else { return }
        thread.append(LiveAssistExchange(.ask(trimmed)))
        dispatch(question: trimmed, mode: .assist)
    }

    /// Returns to listening after the user has read an answer.
    public func dismissAnswer() {
        if case .answered = phase { phase = .listening }
        if case .failed = phase { phase = .listening }
    }

    private func dispatch(question: String?, mode: AssistMode = .assist) {
        guard !windowLines.isEmpty else {
            phase = .failed("No conversation heard yet")
            thread.append(LiveAssistExchange(.failed("No conversation heard yet")))
            return
        }
        let window = windowLines.suffix(24).joined(separator: "\n")
        let instructions = composedInstructions()
        let knowledgeFolder = UserDefaults.standard.string(forKey: Self.knowledgeFolderKey)
        phase = .thinking
        pendingMode = mode
        answerTask = Task { [weak self] in
            let answer = await LiveAnswerService().answer(
                window: window,
                question: question,
                mode: mode,
                instructions: instructions,
                knowledgeFolder: knowledgeFolder)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.pendingMode = nil
            if let answer {
                self.phase = .answered(answer)
                self.thread.append(LiveAssistExchange(.answer(mode: mode, text: answer)))
            } else {
                let message = "No answer. Check your agent in Settings."
                self.phase = .failed(message)
                self.thread.append(LiveAssistExchange(.failed(message)))
            }
        }
    }

    private func composedInstructions() -> String? {
        guard let promptStore else { return nil }
        let parts = [
            promptStore.text(.liveAssist, scope: .global),
            promptStore.text(.liveAssist, scope: .nextCall),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return PromptTemplate.render(
            parts.joined(separator: "\n\n"),
            project: nil,
            attendees: attendeesProvider(),
            date: .now)
    }
}
