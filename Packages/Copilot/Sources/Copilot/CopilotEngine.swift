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
    /// A Look is reading the screen (before its request goes out).
    public private(set) var isLooking = false
    /// The last Look stopped because Screen Recording isn't allowed.
    public private(set) var screenPermissionNeeded = false
    /// The screen text each Look sent, by exchange: memory only, never
    /// sealed with the session, gone when the call ends.
    public private(set) var screenSnapshots: [UUID: ScreenSnapshot] = [:]

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
    @ObservationIgnored private let screenReader: (@MainActor () async throws -> ScreenSnapshot)?
    /// Reads the window with one masked picture of it, for Send image.
    @ObservationIgnored private let imageReader: (@MainActor () async throws -> ScreenSnapshot)?
    @ObservationIgnored private var lookTask: Task<Void, Never>?
    /// An answer started from in-progress words, before their line was final.
    @ObservationIgnored private var early: (question: String, id: UUID)?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
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
    /// The action id Look answers carry in the thread.
    public static let lookActionID = "look"
    /// How long in-progress words must sit still before a question without
    /// a question mark counts as finished.
    public static let earlyPause: Duration = .milliseconds(600)

    public init(
        playbook: Playbook,
        context: SessionContext,
        service: any ClaudeService,
        defaults: UserDefaults = .standard,
        transcript: @escaping @MainActor () -> LiveTranscript,
        callTime: @escaping @MainActor () -> TimeInterval,
        screenReader: (@MainActor () async throws -> ScreenSnapshot)? = nil,
        imageReader: (@MainActor () async throws -> ScreenSnapshot)? = nil
    ) {
        self.playbook = playbook
        self.context = context
        self.service = service
        self.defaults = defaults
        self.transcript = transcript
        self.callTime = callTime
        self.screenReader = screenReader
        self.imageReader = imageReader
        self.autoSuggestEnabled = playbook.autoSuggest
        self.liveNotesEnabled = playbook.liveNotes
        self.composer = PromptComposer(playbook: playbook, context: context)
    }

    public var isStreaming: Bool { streamingID != nil }

    /// The newest exchange (what the answer card shows).
    public var latest: CopilotExchange? { thread.last }

    public var pinned: [CopilotExchange] { thread.filter(\.isPinned) }

    /// This session can read the screen.
    public var canLook: Bool { screenReader != nil }

    /// Send image is on in Settings and this session can capture a picture.
    public var canSendImage: Bool { imageReader != nil && LookSettings.sendsImages(defaults) }

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

    /// Look: reads the frontmost window on this Mac and answers with the
    /// call and the screen together. `question` comes from the Ask field.
    /// The screen text rides in the request's uncached tail and stays in
    /// memory for What was sent; it is never sealed with the session.
    /// With `withImage` (Send image, only when it's on in Settings), one
    /// picture of the window goes too, secret-looking lines blacked out.
    public func look(question: String? = nil, withImage: Bool = false) {
        guard !finished, !isLooking else { return }
        let reader: (@MainActor () async throws -> ScreenSnapshot)?
        if withImage {
            guard canSendImage else { return }
            reader = imageReader
        } else {
            reader = screenReader
        }
        guard let screenReader = reader else { return }
        let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let asked: String? = trimmed.isEmpty ? nil : trimmed
        isLooking = true
        lookTask = Task { [weak self] in
            let outcome: Result<ScreenSnapshot, ScreenReadError>
            do {
                outcome = .success(try await screenReader())
            } catch let error as ScreenReadError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.failed(String(describing: type(of: error))))
            }
            guard let self else { return }
            self.isLooking = false
            guard !self.finished, !Task.isCancelled else { return }
            switch outcome {
            case .success(let snapshot):
                self.screenPermissionNeeded = false
                let id = self.start(
                    .look(snapshot, question: asked), kind: .action, actionID: Self.lookActionID,
                    title: snapshot.image == nil ? "Look" : "Look with image", prompt: asked ?? snapshot.sourceLabel)
                if let id { self.screenSnapshots[id] = snapshot }
            case .failure(let error):
                self.screenPermissionNeeded = error == .permissionNeeded
                self.notice = error.userMessage
            }
        }
    }

    /// More detail or another try on an earlier answer. A Look's rework
    /// sees the same screen text again.
    public func refine(_ id: UUID, _ refinement: PromptComposer.Refinement) {
        guard let original = thread.first(where: { $0.id == id }), !original.response.isEmpty else { return }
        let snapshot = screenSnapshots[id]
        let task: PromptComposer.LiveTask = if let snapshot {
            .refineLook(snapshot, previous: original.response, refinement: refinement)
        } else {
            .refine(previous: original.response, refinement: refinement)
        }
        let newID = start(
            task, kind: original.kind, actionID: original.actionID,
            title: "\(original.title) · \(refinement.title.lowercased())", prompt: original.prompt)
        if let newID, let snapshot { screenSnapshots[newID] = snapshot }
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
                screenSnapshots[id] = nil
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

    /// Called with the other side's in-progress words. With auto-suggest on,
    /// a question that sounds finished is answered before its line is final:
    /// at once when it ends in "?", or after a short pause in the words.
    public func handlePartial(_ text: String) {
        pauseTask?.cancel()
        guard !finished, autoSuggestEnabled, early == nil,
              let question = QuestionDetector.extractQuestion(text) else { return }
        if question.hasSuffix("?") {
            answerEarly(question)
        } else if Self.wordCount(question) >= 6 {
            pauseTask = Task { [weak self] in
                try? await Task.sleep(for: Self.earlyPause)
                guard !Task.isCancelled else { return }
                self?.answerEarly(question)
            }
        }
    }

    private func answerEarly(_ question: String) {
        guard !finished, autoSuggestEnabled, early == nil, !isStreaming,
              Self.wordCount(question) >= 4,
              callTime() - lastAutoAnswer >= Self.autoAnswerCooldown,
              let action = answerAction else { return }
        lastAutoAnswer = callTime()
        pendingQuestion = nil
        if let id = start(.action(action, focus: question), kind: .suggestion, actionID: action.id,
                          title: "They asked", prompt: question) {
            early = (question, id)
        }
    }

    /// Called for every committed transcript line. Detects questions from
    /// the other side and, with auto-suggest on, answers them. A line an
    /// early answer already covered is not answered twice.
    public func handleCommitted(_ entry: LiveTranscript.Entry) {
        guard !finished, entry.lane == .them else { return }
        pauseTask?.cancel()
        let found = QuestionDetector.extractQuestion(entry.segment.text)
        if let started = early {
            early = nil
            // Still on the card (not cut off by another action) and the same
            // question: it was answered while they were still speaking.
            let survived = thread.contains { $0.id == started.id }
            if survived, let found, Self.sameQuestion(started.question, found) { return }
            // The line ended differently, or the early answer was cut off:
            // drop it and treat the final line as usual.
            if streamingID == started.id { cancel() }
            thread.removeAll { $0.id == started.id }
            lastAutoAnswer = -.infinity
        }
        guard let question = found else { return }
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
        lookTask?.cancel()
        pauseTask?.cancel()
        early = nil
        isLooking = false
        // Screen text never outlives the call.
        screenSnapshots.removeAll()
        if let id = streamingID, let index = thread.firstIndex(where: { $0.id == id }), thread[index].response.isEmpty {
            thread.remove(at: index)
        }
        streamingID = nil
        isUpdatingNotes = false
        pendingQuestion = nil
        return (thread, notes, ledger)
    }

    // MARK: - Matching questions

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The same question, give or take punctuation, case, a few trailing
    /// words, or a small rewording by the transcriber.
    static func sameQuestion(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> [Substring] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if long.starts(with: short), long.count - short.count <= 3 { return true }
        let shortSet = Set(short), longSet = Set(long)
        return Double(shortSet.intersection(longSet).count) / Double(shortSet.union(longSet).count) >= 0.8
    }

    // MARK: - Streaming

    private var answerAction: QuickAction? {
        playbook.quickActions.first { $0.kind == .answer } ?? StandardActions.answer
    }

    @discardableResult
    private func start(
        _ task: PromptComposer.LiveTask,
        kind: CopilotExchange.Kind,
        actionID: String?,
        title: String,
        prompt: String?
    ) -> UUID? {
        guard !finished else { return nil }
        cancel()
        let now = callTime()
        let model = ModelRole.live.modelID(defaults: defaults)
        let request = composer.liveRequest(
            task, transcript: transcript(), now: now, recent: Array(thread.suffix(3)), model: model,
            maxTokens: task.isLook ? 900 : 500)
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
        return id
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
