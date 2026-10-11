import AnthropicKit
import Core
import Foundation
import Observation
import Transcription
import os

/// The live copilot for one call: runs quick actions and asks against the
/// live transcript, streams answers into a thread, answers detected
/// questions on its own when auto-suggest is on, and keeps running notes.
/// Every failure is quiet and local: the recording never depends on it.
@MainActor
@Observable
public final class CopilotEngine {

    /// A question the other side asked, waiting for the user (or auto-suggest).
    public struct DetectedQuestion: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let text: String
        public let callTime: TimeInterval
    }

    public private(set) var thread: [CopilotExchange] = []
    /// The exchange currently streaming, if any.
    public private(set) var streamingID: UUID?
    public private(set) var notes: LiveNotes?
    public private(set) var isUpdatingNotes = false
    public private(set) var pendingQuestion: DetectedQuestion?
    public private(set) var ledger = UsageLedger()
    /// Calm inline status ("Claude is busy…"), cleared by the next success.
    public private(set) var notice: String?
    /// Rolling first-token latencies (seconds) for Settings.
    public private(set) var firstTokenSamples: [Double] = []

    public var playbook: Playbook {
        didSet { composer.playbook = playbook }
    }
    public var context: SessionContext {
        didSet { composer.context = context }
    }
    public var autoSuggestEnabled: Bool
    public var liveNotesEnabled: Bool

    @ObservationIgnored private var composer: PromptComposer
    @ObservationIgnored private let service: any ClaudeService
    @ObservationIgnored private let transcript: @MainActor () -> LiveTranscript
    @ObservationIgnored private let callTime: @MainActor () -> TimeInterval
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var notesTask: Task<Void, Never>?
    @ObservationIgnored private var lastAutoAnswer: TimeInterval = -.infinity
    @ObservationIgnored private var lastNotesTime: TimeInterval = -.infinity
    @ObservationIgnored private var lastNotesWordCount = 0
    @ObservationIgnored private var finished = false

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "Copilot")

    /// Seconds between automatic answers.
    public static let autoAnswerCooldown: TimeInterval = 15
    /// Live notes refresh no more often than this, and only after enough new talk.
    public static let notesInterval: TimeInterval = 75
    public static let notesMinimumNewWords = 60

    public init(
        playbook: Playbook,
        context: SessionContext,
        service: any ClaudeService,
        defaults: UserDefaults = .standard,
        transcript: @escaping @MainActor () -> LiveTranscript,
        callTime: @escaping @MainActor () -> TimeInterval
    ) {
        self.playbook = playbook
        self.context = context
        self.service = service
        self.defaults = defaults
        self.transcript = transcript
        self.callTime = callTime
        self.autoSuggestEnabled = playbook.autoSuggest
        self.liveNotesEnabled = playbook.liveNotes
        self.composer = PromptComposer(playbook: playbook, context: context)
    }

    public var isStreaming: Bool { streamingID != nil }

    /// The newest exchange (what the answer card shows).
    public var latest: CopilotExchange? { thread.last }

    public var pinned: [CopilotExchange] { thread.filter(\.isPinned) }

    // MARK: - User intents

    /// Runs a quick action. An answer-type action takes the pending question as its focus.
    public func run(_ action: QuickAction) {
        var focus: String?
        if action.kind == .answer, let pending = pendingQuestion {
            focus = pending.text
            pendingQuestion = nil
        }
        start(.action(action, focus: focus), kind: .action, actionID: action.id, title: action.title, prompt: focus)
    }

    /// The user's own question.
    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        start(.ask(trimmed), kind: .ask, actionID: nil, title: trimmed, prompt: trimmed)
    }

    /// Answers the pending detected question now.
    public func answerPending() {
        guard let pending = pendingQuestion, let action = answerAction else { return }
        pendingQuestion = nil
        start(.action(action, focus: pending.text), kind: .suggestion, actionID: action.id,
              title: "They asked", prompt: pending.text)
    }

    public func dismissPending() {
        pendingQuestion = nil
    }

    /// More detail or another try on an earlier answer.
    public func refine(_ id: UUID, _ refinement: PromptComposer.Refinement) {
        guard let original = thread.first(where: { $0.id == id }), !original.response.isEmpty else { return }
        start(.refine(previous: original.response, refinement: refinement),
              kind: original.kind, actionID: original.actionID,
              title: "\(original.title) · \(refinement.title.lowercased())", prompt: original.prompt)
    }

    public func togglePin(_ id: UUID) {
        guard let index = thread.firstIndex(where: { $0.id == id }) else { return }
        thread[index].isPinned.toggle()
    }

    /// Stops the answer in flight (keeps whatever arrived).
    public func cancel() {
        answerTask?.cancel()
        answerTask = nil
        if let id = streamingID, let index = thread.firstIndex(where: { $0.id == id }) {
            if thread[index].response.isEmpty {
                thread.remove(at: index)
            }
        }
        streamingID = nil
    }

    /// Opens the connection before the first question.
    public func prewarm() {
        let service = self.service
        Task.detached { await service.prewarm() }
    }

    // MARK: - Session feed

    /// Called for every committed transcript line. Detects questions from
    /// the other side and, with auto-suggest on, answers them.
    public func handleCommitted(_ entry: LiveTranscript.Entry) {
        guard !finished, entry.lane == .them,
              let question = QuestionDetector.extractQuestion(entry.segment.text) else { return }
        let detected = DetectedQuestion(id: UUID(), text: question, callTime: entry.segment.start)
        pendingQuestion = detected
        guard autoSuggestEnabled, !isStreaming,
              callTime() - lastAutoAnswer >= Self.autoAnswerCooldown,
              let action = answerAction else { return }
        lastAutoAnswer = callTime()
        pendingQuestion = nil
        start(.action(action, focus: question), kind: .suggestion, actionID: action.id,
              title: "They asked", prompt: question)
    }

    /// Periodic housekeeping (the session calls this every few seconds).
    public func tick() {
        guard !finished, liveNotesEnabled, !isUpdatingNotes else { return }
        let snapshot = transcript()
        let words = snapshot.entries.reduce(0) { $0 + $1.segment.text.split(separator: " ").count }
        let now = callTime()
        guard words - lastNotesWordCount >= Self.notesMinimumNewWords,
              now - lastNotesTime >= Self.notesInterval else { return }
        refreshNotes()
    }

    /// Updates the running notes now.
    public func refreshNotes() {
        guard !finished, !isUpdatingNotes else { return }
        let snapshot = transcript()
        guard !snapshot.entries.isEmpty else { return }
        let now = callTime()
        let model = ModelRole.notes.modelID(defaults: defaults)
        let request = composer.notesRequest(transcript: snapshot, now: now, previous: notes, model: model)
        isUpdatingNotes = true
        lastNotesTime = now
        lastNotesWordCount = snapshot.entries.reduce(0) { $0 + $1.segment.text.split(separator: " ").count }
        let service = self.service
        notesTask = Task { [weak self] in
            var text = ""
            var finishedResult: StreamResult?
            do {
                for try await event in service.streamText(request, deadline: .seconds(60)) {
                    switch event {
                    case .text(let piece): text += piece
                    case .finished(let result): finishedResult = result
                    case .started: break
                    }
                }
            } catch {
                Self.log.info("notes refresh failed: \(String(describing: error), privacy: .public)")
            }
            guard let self else { return }
            self.isUpdatingNotes = false
            if let finishedResult {
                self.ledger.add(UsageRecord(role: .notes, result: finishedResult))
            }
            if let parsed = LiveNotes.parse(text, coveredUntil: now) {
                self.notes = parsed
            }
        }
    }

    /// Ends the copilot for this call: cancels work, returns what to seal.
    public func finish() -> (thread: [CopilotExchange], notes: LiveNotes?, ledger: UsageLedger) {
        finished = true
        answerTask?.cancel()
        notesTask?.cancel()
        if let id = streamingID, let index = thread.firstIndex(where: { $0.id == id }), thread[index].response.isEmpty {
            thread.remove(at: index)
        }
        streamingID = nil
        isUpdatingNotes = false
        pendingQuestion = nil
        return (thread, notes, ledger)
    }

    // MARK: - Streaming

    private var answerAction: QuickAction? {
        playbook.quickActions.first { $0.kind == .answer } ?? StandardActions.answer
    }

    private func start(
        _ task: PromptComposer.LiveTask,
        kind: CopilotExchange.Kind,
        actionID: String?,
        title: String,
        prompt: String?
    ) {
        guard !finished else { return }
        cancel()
        let now = callTime()
        let model = ModelRole.live.modelID(defaults: defaults)
        let request = composer.liveRequest(
            task, transcript: transcript(), now: now, recent: Array(thread.suffix(3)), model: model)
        let exchange = CopilotExchange(
            kind: kind, actionID: actionID, title: title, prompt: prompt, callTime: now, model: model)
        thread.append(exchange)
        streamingID = exchange.id
        let id = exchange.id
        let service = self.service
        answerTask = Task { [weak self] in
            do {
                for try await event in service.streamText(request, deadline: .seconds(45)) {
                    guard let self else { return }
                    switch event {
                    case .text(let piece):
                        self.append(piece, to: id)
                    case .finished(let result):
                        self.complete(id, result: result)
                    case .started:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as AnthropicError {
                self?.fail(id, error.userMessage)
            } catch {
                self?.fail(id, "Something went wrong. Try again.")
            }
            if let self, self.streamingID == id { self.streamingID = nil }
        }
    }

    private func append(_ piece: String, to id: UUID) {
        guard let index = thread.firstIndex(where: { $0.id == id }) else { return }
        thread[index].response += piece
    }

    private func complete(_ id: UUID, result: StreamResult) {
        ledger.add(UsageRecord(role: .live, result: result))
        notice = nil
        if let index = thread.firstIndex(where: { $0.id == id }) {
            thread[index].model = result.model
            thread[index].firstTokenSeconds = result.timeToFirstToken?.seconds
            thread[index].response = thread[index].response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let ttft = result.timeToFirstToken?.seconds {
            firstTokenSamples.append(ttft)
            if firstTokenSamples.count > 50 { firstTokenSamples.removeFirst() }
        }
        if streamingID == id { streamingID = nil }
    }

    private func fail(_ id: UUID, _ message: String) {
        if let index = thread.firstIndex(where: { $0.id == id }) {
            thread[index].failure = message
        }
        notice = message
        if streamingID == id { streamingID = nil }
    }
}
