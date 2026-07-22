import AgentBridge
import AppKit
import AudioCapture
import CalendarContext
import ClaudeBridge
import Core
import Extraction
import Foundation
import Matching
import Observation
import Persistence
import Transcription
import os

/// Orchestrates the whole MVP loop on the main actor: hotkey → resolve the
/// conferencing target → two-lane capture → batch transcription → merged
/// Me/Them transcript, driving ``SessionStateMachine`` and publishing state
/// for the UI.
@MainActor
@Observable
public final class CallController {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "CallController")

    /// Lifecycle state (state machine output).
    public private(set) var state: SessionState = .idle
    /// Live Me/Them meters while recording.
    public private(set) var levels: CaptureLevels?
    /// Human-readable processing progress ("Downloading model 42%", …).
    public private(set) var processingDetail = ""
    /// The silence watchdog's non-blocking "Still recording?" prompt.
    public private(set) var silencePromptVisible = false
    /// Where the current/last session's files live.
    public private(set) var sessionDirectory: URL?

    /// UI hook: called (main actor) when a processed call opens for review.
    @ObservationIgnored public var onReview: (@MainActor (ReviewContext) -> Void)?

    /// Prefilter shortlist of the last processed call (island display).
    public private(set) var lastMatches: [ScoredCandidate] = []
    /// The routed agent's judgment for the last processed call, if it ran.
    public private(set) var lastJudgment: CallJudgment?

    /// The background processing queue: stopping a recording enqueues it
    /// and frees the state machine immediately, so the next call can start
    /// while earlier ones transcribe, match, and judge. Serial worker —
    /// the whisper context and the agent are one-at-a-time resources.
    public private(set) var jobs: [ProcessingJob] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var reviewOpenID: UUID?
    /// Serializes whisper use between the queue worker and Live Assist.
    let whisperGate = AsyncGate()

    /// A job is being (or waiting to be) processed.
    public var queueBusy: Bool {
        jobs.contains {
            switch $0.status {
            case .waiting, .running: true
            default: false
            }
        }
    }

    /// Processed calls whose review has not been opened yet.
    public var hasReadyReview: Bool {
        jobs.contains { $0.status == .ready }
    }

    private let agentRegistry = AgentRegistry.standard

    /// Audio retention (recommended default: delete WAVs once transcribed).
    public var retention = RetentionPolicy()
    private let encryption = try? EncryptionService()
    /// Learned filing signals; fed only by confirmed write-backs.
    @ObservationIgnored private lazy var filingMemory: FilingMemory? =
        encryption.map { FilingMemory(encryption: $0) }
    /// User-authored vocabulary and filing instructions (issue #2).
    @ObservationIgnored private lazy var promptStore: PromptStore? =
        encryption.map { PromptStore(encryption: $0) }
    /// The Live Assist copilot (issue #8); off unless opted in AND prompted.
    public let liveAssist = LiveAssistController()
    @ObservationIgnored private var storeCache: SessionStore?
    private var store: SessionStore? {
        if storeCache == nil { storeCache = try? SessionStore() }
        return storeCache
    }
    private var sessionStartedAt: Date = .now

    private var captureSession: CaptureSession?
    private var eventTask: Task<Void, Never>?
    private var watchdog = SilenceWatchdog()
    private let modelManager = ModelManager()
    private let calendarReader = CalendarReader()
    private var callCalendarContext: Core.CalendarContext?
    /// Kept across calls so the ~1.6 GB model loads once per app run.
    private var cachedTranscriber: WhisperTranscriber?

    public init() {}

    // MARK: - State machine driver

    @discardableResult
    private func apply(_ event: SessionEvent) -> Bool {
        guard let next = SessionStateMachine.reduce(state, event) else {
            Self.log.info("ignored \(event.logLabel, privacy: .public) in \(self.state.logLabel, privacy: .public)")
            return false
        }
        Self.log.info("\(self.state.logLabel, privacy: .public) → \(next.logLabel, privacy: .public) (\(event.logLabel, privacy: .public))")
        state = next
        return true
    }

    // MARK: - Hotkey

    /// The global hotkey (and the menu's Start/Stop item).
    public func toggle() {
        switch state {
        case .idle, .done, .error:
            guard apply(.hotkeyPressed) else { return }
            Task { await startRecording() }
        case .recording:
            guard apply(.hotkeyPressed) else { return }
            Task { await stopAndProcess() }
        case .armed, .processing, .review:
            break // mid-transition or review open; hotkey is a no-op
        }
    }

    /// "Still here" on the silence prompt.
    public func dismissSilencePrompt() {
        watchdog.dismissPrompt()
        silencePromptVisible = false
    }

    /// Whether the "Me" lane is currently muted (records silence).
    public private(set) var micMuted = false

    /// Mutes/unmutes the mic lane mid-recording.
    public func setMicMuted(_ muted: Bool) {
        micMuted = muted
        captureSession?.setMicMuted(muted)
    }

    // MARK: - Review lifecycle (job-scoped)

    /// Opens review for a specific queued call (hub Queue pane, island
    /// peek). One review window at a time.
    public func openReview(id: UUID) {
        guard reviewOpenID == nil,
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status == .ready,
              let context = jobs[index].context else { return }
        jobs[index].status = .reviewing
        reviewOpenID = id
        onReview?(context)
    }

    /// Opens the newest processed call awaiting review.
    public func openLatestReadyReview() {
        if let job = jobs.last(where: { $0.status == .ready }) {
            openReview(id: job.id)
        }
    }

    /// The review surface for `context` was closed.
    public func reviewClosed(_ context: ReviewContext) {
        if let index = jobs.firstIndex(where: { $0.id == context.id }) {
            jobs[index].status = .done
        }
        if reviewOpenID == context.id { reviewOpenID = nil }
        let store = store
        Task { try? await store?.updateStatus(id: context.id, status: "done") }
        maybePresentNextReview()
    }

    /// Auto-presents the oldest ready review, but never over an open
    /// review and never while the user is capturing another call.
    private func maybePresentNextReview() {
        guard reviewOpenID == nil, state == .idle,
              let index = jobs.firstIndex(where: { $0.status == .ready }),
              let context = jobs[index].context else { return }
        jobs[index].status = .reviewing
        reviewOpenID = context.id
        onReview?(context)
    }

    /// Drops finished (done/failed) jobs from the visible queue.
    public func clearFinishedJobs() {
        jobs.removeAll {
            switch $0.status {
            case .done, .failed: true
            default: false
            }
        }
    }

    /// The confirmed write-back: routes the approved extracted items into the
    /// matched project, additively and conflict-safe. Returns per-file
    /// outcomes for the review surface. The ONLY path that touches a repo.
    public func applyWriteBack(context: ReviewContext, approvedItems: [Int]) -> [WriteOutcome] {
        guard let judgment = context.judgment, judgment.isConfident,
              let projectPath = judgment.match.projectPath else { return [] }
        let changes = WriteBackRouter.plan(judgment: judgment, approvedItems: approvedItems)
        let engine = WriteBackEngine(projectRoot: URL(filePath: projectPath))
        let outcomes = engine.apply(changes.map { engine.preview($0) })
        // Record the outcomes inside the encrypted session archive.
        if let encryption {
            let archiveURL = context.sessionDirectory.appendingPathComponent("session.enc")
            let report = outcomes.map { outcome -> String in
                switch outcome {
                case .applied(let file): "applied: \(file)"
                case .conflict(let file, let diff): "conflict: \(file)\n\(diff)"
                case .failed(let file, let reason): "failed: \(file) — \(reason)"
                }
            }
            if var archive = try? encryption.decrypt(SessionArchive.self, from: archiveURL) {
                archive.notes += report
                try? encryption.encrypt(archive, to: archiveURL)
            }
        }
        // A confirmed write is the strongest correction signal there is:
        // remember the meeting link and fold the call vector into this
        // project's centroid so similar future calls boost it.
        let anythingApplied = outcomes.contains {
            if case .applied = $0 { true } else { false }
        }
        if anythingApplied {
            if let title = context.meetingTitle {
                filingMemory?.rememberMeeting(title, project: projectPath)
            }
            if let vector = context.transcriptVector {
                filingMemory?.rememberVector(vector, project: projectPath)
            }
        }
        return outcomes
    }

    /// Forgets all learned filing signals (Settings action).
    public func clearFilingMemory() {
        filingMemory?.clear()
    }

    /// The custom-prompt store, shared with the hub's Prompts pane.
    public var prompts: PromptStore? { promptStore }

    /// Project directories every installed agent knows — the hub's Prompts
    /// pane offers them as per-project scopes.
    public func knownProjectPaths() -> [String] {
        AgentRegistry.mergedCandidates(
            from: agentRegistry.installedProviders().map { $0.knownProjects() })
            .map(\.path.path)
            .sorted()
    }

    // MARK: - Recording

    private func startRecording() async {
        levels = nil
        silencePromptVisible = false
        micMuted = false
        watchdog = SilenceWatchdog()

        guard let target = resolveTarget() else {
            _ = apply(.captureFailed("No conferencing app with audio found. Join the call first, then press the hotkey."))
            return
        }

        let stamp = Self.timestamp()
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("Saaa/Sessions/\(stamp)", isDirectory: true)
        sessionDirectory = directory

        let session = CaptureSession(configuration: CaptureConfiguration(
            target: .process(target.pid), outputDirectory: directory))
        captureSession = session

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in session.events {
                await self?.handleCapture(event)
            }
        }

        do {
            try await session.start()
            sessionStartedAt = .now
            _ = apply(.captureStarted)
            // Snapshot the overlapping calendar event off the hot path —
            // first use shows the calendar permission dialog in context.
            callCalendarContext = nil
            Task { [weak self] in
                guard let self else { return }
                let context = await calendarReader.eventOverlapping()
                self.callCalendarContext = context
            }
            if LiveAssistController.isArmed(promptStore: promptStore) {
                liveAssist.begin(
                    micURL: directory.appendingPathComponent("mic.wav"),
                    systemURL: directory.appendingPathComponent("system.wav"),
                    gate: whisperGate,
                    promptStore: promptStore,
                    attendeesProvider: { [weak self] in
                        self?.callCalendarContext?.attendees ?? []
                    },
                    transcriberProvider: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.ensureTranscriber()
                    })
            }
        } catch {
            captureSession = nil
            _ = apply(.captureFailed(Self.describe(error)))
        }
    }

    private func resolveTarget() -> TargetPicker.Candidate? {
        let apps = (try? AudioProcessDirectory.appLevelSnapshot(
            excluding: ProcessInfo.processInfo.processIdentifier)) ?? []
        let candidates = apps.map { entry in
            TargetPicker.Candidate(
                pid: entry.id,
                bundleID: NSRunningApplication(processIdentifier: entry.id)?.bundleIdentifier,
                name: entry.name,
                isPlayingAudio: entry.isPlayingAudio)
        }
        return TargetPicker.pick(from: candidates)
    }

    private func handleCapture(_ event: CaptureEvent) async {
        switch event {
        case .levels(let reading):
            levels = reading
            switch watchdog.feed(mic: reading.mic.rms, system: reading.system.rms, at: reading.time) {
            case .quiet:
                if silencePromptVisible { silencePromptVisible = false }
            case .prompt:
                silencePromptVisible = true
            case .timedOut:
                silencePromptVisible = false
                if state == .recording, apply(.captureStopped) {
                    await stopCaptureThenEnqueue()
                }
            }
        case .stopped(let reason):
            // Auto-stop (target quit, device loss, failure) while recording.
            if state == .recording, apply(.captureStopped) {
                if case .failed(let failure) = reason {
                    _ = apply(.transcriptionFailed("Capture failed: \(failure)"))
                    return
                }
                await enqueueCapturedSession()
            }
        case .systemAudioPermissionSuspected:
            Self.log.warning("system lane all-zero — System Audio Recording grant suspected missing")
        default:
            break
        }
    }

    private func stopAndProcess() async {
        await stopCaptureThenEnqueue()
    }

    private func stopCaptureThenEnqueue() async {
        guard let session = captureSession else { return }
        do {
            _ = try await session.stop()
        } catch {
            Self.log.error("stop failed: \(error, privacy: .public)")
        }
        await enqueueCapturedSession()
    }

    // MARK: - Import

    /// Manual context attached to an import: stands in for the calendar
    /// when the file's creation time has no event, and wins over it when
    /// provided.
    public struct ImportContext: Sendable, Equatable {
        public var title: String
        /// Comma-separated names.
        public var attendees: String

        public init(title: String = "", attendees: String = "") {
            self.title = title
            self.attendees = attendees
        }
    }

    /// Runs an existing audio or video recording through the same pipeline
    /// as a live call (issue #3). Valid only outside an active session.
    /// Imported media gets the same sealing and retention as live audio.
    public func importRecording(_ fileURL: URL, context manual: ImportContext = ImportContext()) {
        guard apply(.importStarted) else { return }
        Task { await runImport(fileURL, manual: manual) }
    }

    private func runImport(_ fileURL: URL, manual: ImportContext) async {
        let stamp = Self.timestamp()
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("Saaa/Sessions/\(stamp)-import", isDirectory: true)
        sessionDirectory = directory
        sessionStartedAt = .now
        do {
            processingDetail = "Preparing audio…"
            let imported = try await MediaImporter.extract(from: fileURL, into: directory)

            // The event overlapping the file's creation time stands in for
            // the live calendar snapshot; manual context wins where given.
            let created = (try? fileURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created { sessionStartedAt = created }
            var calendar: Core.CalendarContext?
            if let created { calendar = await calendarReader.eventOverlapping(created) }
            let title = manual.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let attendees = manual.attendees
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !title.isEmpty || !attendees.isEmpty {
                calendar = Core.CalendarContext(
                    title: title.isEmpty
                        ? (calendar?.title ?? fileURL.deletingPathExtension().lastPathComponent)
                        : title,
                    attendees: attendees.isEmpty ? (calendar?.attendees ?? []) : attendees,
                    notes: calendar?.notes)
            }
            processingDetail = ""
            enqueue(ProcessingJob(
                title: calendar?.title ?? fileURL.deletingPathExtension().lastPathComponent,
                startedAt: sessionStartedAt,
                micWAV: imported.micWAV,
                systemWAV: imported.systemWAV,
                duration: imported.duration,
                directory: directory,
                calendar: calendar,
                context: nil))
        } catch {
            processingDetail = ""
            _ = apply(.transcriptionFailed(Self.describe(error)))
        }
    }

    // MARK: - Processing queue

    private func enqueueCapturedSession() async {
        guard case .processing = state,
              let session = captureSession,
              let result = await session.result,
              let directory = sessionDirectory else { return }
        captureSession = nil
        eventTask?.cancel()
        eventTask = nil
        levels = nil
        // Thread snapshot before shutdown clears the copilot state.
        let assistThread = liveAssist.takeThread()
        await liveAssist.shutdownAndWait()
        enqueue(ProcessingJob(
            title: callCalendarContext?.title
                ?? "Call \(sessionStartedAt.formatted(date: .omitted, time: .shortened))",
            startedAt: sessionStartedAt,
            micWAV: result.micFileURL,
            systemWAV: result.systemFileURL,
            duration: result.duration,
            directory: directory,
            calendar: callCalendarContext,
            assistThread: assistThread,
            context: nil))
    }

    /// Appends a job, frees the state machine, and pumps the worker.
    private func enqueue(_ job: ProcessingJob) {
        jobs.append(job)
        _ = apply(.queued)
        pump()
    }

    private func pump() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let id = self.jobs.first(where: { $0.status == .waiting })?.id {
                await self.process(jobID: id)
            }
            self?.worker = nil
            self?.maybePresentNextReview()
        }
    }

    /// The shared pipeline tail for live calls and imports: transcribe the
    /// lane(s), merge, match, judge, seal, and hand off to review. A nil
    /// `micWAV` (mono import) yields a single unattributed lane.
    /// Loads (or reuses) the shared whisper context. Also used by Live
    /// Assist, which must be fully drained before batch transcription runs.
    private func ensureTranscriber() async throws -> WhisperTranscriber {
        let modelURL = try await modelManager.ensure(.largeV3Turbo) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.processingDetail =
                    "Downloading model \(Int(progress.fraction * 100))% (one-time, 1.6 GB)"
            }
        }
        let vadURL = try await modelManager.ensure(.sileroVAD)
        if cachedTranscriber == nil {
            cachedTranscriber = try WhisperTranscriber(modelPath: modelURL, vadModelPath: vadURL)
        }
        guard let transcriber = cachedTranscriber else {
            throw CancellationError()
        }
        return transcriber
    }

    private func setJobDetail(_ id: UUID, _ text: String) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].status = .running(text)
        }
        processingDetail = text
    }

    private func process(jobID: UUID) async {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        do {
            setJobDetail(jobID, "Preparing models…")
            let transcriber = try await ensureTranscriber()

            // Custom vocabulary + calendar terms pre-warm Whisper's proper
            // nouns. Project-scoped vocabulary applies when the learned
            // meeting link already names the project (matching happens
            // after transcription, so this is the only pre-hoc hint).
            var vocabularySources = [promptStore?.text(.vocabulary, scope: .global)]
            if let title = job.calendar?.title,
               let linked = filingMemory?.projectPath(forMeeting: title) {
                vocabularySources.append(
                    promptStore?.text(.vocabulary, scope: .project(path: linked)))
            }
            vocabularySources.append(promptStore?.text(.vocabulary, scope: .nextCall))
            let customTerms = PromptResolver.vocabularyTerms(vocabularySources)
            let bias = VocabularyBias.initialPrompt(
                terms: customTerms + (job.calendar?.signalTerms ?? []))
            // The whisper context is shared with Live Assist (which may be
            // streaming for a NEWER recording right now) — gate it.
            await whisperGate.lock()
            let transcript: Transcript
            do {
                if let micWAV = job.micWAV {
                    setJobDetail(jobID, "Transcribing your side…")
                    let mic = try await transcriber.transcribe(
                        wavFile: micWAV, initialPrompt: bias)
                    setJobDetail(jobID, "Transcribing their side…")
                    let system = try await transcriber.transcribe(
                        wavFile: job.systemWAV, initialPrompt: bias)
                    transcript = TranscriptMerger.merge(mic: mic, system: system)
                } else {
                    setJobDetail(jobID, "Transcribing…")
                    let single = try await transcriber.transcribe(
                        wavFile: job.systemWAV, initialPrompt: bias)
                    transcript = TranscriptMerger.merge(
                        mic: ChannelTranscription(segments: [], language: single.language),
                        system: single)
                }
            } catch {
                await whisperGate.unlock()
                throw error
            }
            await whisperGate.unlock()

            // Phase-5 shortlist: cheap prefilter over every installed
            // agent's memory (Claude Code's store, Codex's sessions),
            // persisted beside the transcript for the judgment.
            setJobDetail(jobID, "Matching projects…")
            let installed = agentRegistry.installedProviders()
            let candidates = AgentRegistry.mergedCandidates(
                from: installed.map { $0.knownProjects() })
            // Hybrid retrieval: keyword + calendar (in the prefilter),
            // learned meeting links, and call-vector similarity as boosts.
            let transcriptVector = TranscriptEmbedder.vector(for: transcript)
            var boosts: [String: Double] = [:]
            let mappedPath = job.calendar.flatMap {
                filingMemory?.projectPath(forMeeting: $0.title)
            }
            if let mappedPath { boosts[mappedPath, default: 0] += 8 }
            if let transcriptVector,
               let similarities = filingMemory?.similarities(to: transcriptVector) {
                for (path, similarity) in similarities where similarity > 0.6 {
                    boosts[path, default: 0] += (similarity - 0.6) / 0.4 * 4
                }
            }
            let matches = Prefilter.rank(
                candidates: candidates, transcript: transcript,
                calendar: job.calendar, boosts: boosts)
            // Stage 2: the routed agent's read-only judgment over the
            // shortlist. The project's provenance picks the agent, the user
            // default breaks ties, and every other installed agent is
            // automatic fallback. Failures degrade gracefully — the
            // transcript always survives, unfiled.
            var judgment: CallJudgment?
            if !matches.isEmpty, !transcript.segments.isEmpty {
                let filing = FilingPreferences.fromDefaults()
                let attempts = agentRegistry.attemptOrder(
                    topCandidateKnownTo: matches.first?.candidate.knownTo ?? [],
                    preferred: filing.preferredAgent,
                    from: installed)
                if attempts.isEmpty {
                    Self.log.info("no coding agent installed — keeping transcript unfiled")
                }
                // Escalation gate: decisive local evidence pins the project
                // and the agent only extracts; uncertainty pays for the
                // full judgment.
                let calendarAgrees = matches.first.map {
                    EscalationGate.calendarAgrees(job.calendar, with: $0.candidate)
                } ?? false
                let decision = EscalationGate.decide(
                    ranked: matches,
                    calendarAgrees: calendarAgrees,
                    meetingMappedPath: mappedPath)
                let pinnedProject: String? = if case .pinned(let choice) = decision {
                    choice.candidate.path.path
                } else {
                    nil
                }
                if pinnedProject != nil {
                    Self.log.info("escalation gate: project pinned by local evidence")
                }
                let shortlist = matches.map {
                    (path: $0.candidate.path.path,
                     name: $0.candidate.name,
                     score: $0.score)
                }
                let provenance = Dictionary(
                    uniqueKeysWithValues: matches.map {
                        ($0.candidate.path.path, Array($0.candidate.knownTo).sorted())
                    })
                // Composed filing instructions: global, project (when
                // pinned; on open judgments the agent reads the repo's own
                // CLAUDE.md/AGENTS.md), conditional call-type blocks, and
                // any one-time next-call prompt. Template-rendered here.
                let instructions: String? = promptStore.flatMap { store in
                    PromptResolver.composeFiling(
                        global: store.text(.filing, scope: .global),
                        project: pinnedProject.flatMap {
                            store.text(.filing, scope: .project(path: $0))
                        },
                        callTypeBlocks: store.callTypeBlocks(.filing),
                        nextCall: store.text(.filing, scope: .nextCall))
                    .map {
                        PromptTemplate.render(
                            $0,
                            project: (pinnedProject ?? matches.first?.candidate.path.path)
                                .map { URL(filePath: $0).lastPathComponent },
                            attendees: job.calendar?.attendees ?? [],
                            date: job.startedAt)
                    }
                }
                for provider in attempts {
                    setJobDetail(jobID, pinnedProject == nil
                        ? "Asking \(provider.displayName)…"
                        : "Extracting with \(provider.displayName)…")
                    do {
                        var result = try await provider.judge(
                            transcript: transcript,
                            shortlist: shortlist,
                            provenance: provenance,
                            calendar: job.calendar,
                            pinnedProject: pinnedProject,
                            instructions: instructions,
                            model: filing.modelIntent,
                            timeout: .seconds(240))
                        result.filedBy = provider.id.rawValue
                        judgment = result
                        break
                    } catch {
                        Self.log.error("\(provider.displayName, privacy: .public) judgment failed: \(String(describing: error), privacy: .public) — falling back if another agent is installed")
                    }
                }
            }
            // One-time prompts are spent regardless of how the call filed.
            promptStore?.clearNextCall()

            // Phase 8 — content is sealed into one encrypted archive; raw
            // audio is deleted per the retention default (text survives,
            // audio does not). Only content-free metadata enters the store.
            setJobDetail(jobID, "Securing…")
            let archive = SessionArchive(
                transcript: transcript,
                calendar: job.calendar,
                matches: matches,
                judgment: judgment,
                assistThread: job.assistThread.isEmpty ? nil : job.assistThread.map { exchange in
                    switch exchange.kind {
                    case .ask(let text):
                        AssistThreadEntry(role: "ask", mode: nil, text: text, at: exchange.at)
                    case .answer(let mode, let text):
                        AssistThreadEntry(
                            role: "answer", mode: mode.displayName, text: text, at: exchange.at)
                    case .failed(let message):
                        AssistThreadEntry(role: "failed", mode: nil, text: message, at: exchange.at)
                    }
                })
            var audioRetained = true
            if let encryption {
                try encryption.encrypt(
                    archive, to: job.directory.appendingPathComponent("session.enc"))
                if retention.autoDeleteAudioAfterTranscription {
                    if let micWAV = job.micWAV { try? FileManager.default.removeItem(at: micWAV) }
                    try? FileManager.default.removeItem(at: job.systemWAV)
                    audioRetained = false
                }
            } else {
                // No keychain key (should not happen): keep nothing on disk
                // rather than write plaintext content.
                Self.log.error("encryption unavailable — session content not persisted")
            }
            try? await store?.insert(SessionStore.Row(
                id: job.id,
                startedAt: job.startedAt,
                duration: job.duration,
                directoryPath: job.directory.path,
                projectPath: judgment?.match.projectPath,
                confidence: judgment?.match.confidence,
                callType: judgment?.callType,
                audioRetained: audioRetained,
                status: "review"))
            processingDetail = ""
            // Mirrors for the island's peek and the menu.
            lastMatches = matches
            lastJudgment = judgment
            let context = ReviewContext(
                id: job.id,
                transcript: transcript,
                matches: matches,
                judgment: judgment,
                sessionDirectory: job.directory,
                meetingTitle: job.calendar?.title,
                transcriptVector: transcriptVector)
            if let index = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[index].context = context
                jobs[index].status = .ready
            }
            maybePresentNextReview()
        } catch {
            processingDetail = ""
            if let index = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[index].status = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Helpers

    private static func describe(_ error: Error) -> String {
        if let captureError = error as? CaptureError {
            switch captureError {
            case .microphonePermissionDenied:
                return "Microphone access is denied. Grant it in System Settings → Privacy & Security → Microphone."
            case .systemAudioPermissionDenied:
                return "System Audio Recording is denied. Add Saaa under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
            case .targetProcessNotFound:
                return "The call app is no longer running."
            default:
                return String(describing: captureError)
            }
        }
        return String(describing: error)
    }

    private static func timestamp() -> String {
        Date().formatted(.verbatim(
            "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
    }
}
