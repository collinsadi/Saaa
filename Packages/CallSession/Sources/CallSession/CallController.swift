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

    /// UI hook: called (main actor) when a transcript enters review.
    @ObservationIgnored public var onReview: (@MainActor (Transcript) -> Void)?

    /// Prefilter shortlist of the last processed call (Phase-6 input).
    public private(set) var lastMatches: [ScoredCandidate] = []
    /// The routed agent's judgment for the last processed call, if it ran.
    public private(set) var lastJudgment: CallJudgment?

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
    /// The call vector of the last processed transcript, kept for learning
    /// when the user confirms the write-back.
    @ObservationIgnored private var lastTranscriptVector: [Double]?
    /// Meeting title captured at judgment time for the same purpose.
    @ObservationIgnored private var lastMeetingTitle: String?
    @ObservationIgnored private var storeCache: SessionStore?
    private var store: SessionStore? {
        if storeCache == nil { storeCache = try? SessionStore() }
        return storeCache
    }
    private var currentRecordID: UUID?
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

    /// The review surface was closed.
    public func closeReview() {
        if apply(.reviewClosed) {
            apply(.reset)
            if let currentRecordID {
                let store = store
                Task { try? await store?.updateStatus(id: currentRecordID, status: "done") }
            }
        }
    }

    /// The confirmed write-back: routes the approved extracted items into the
    /// matched project, additively and conflict-safe. Returns per-file
    /// outcomes for the review surface. The ONLY path that touches a repo.
    public func applyWriteBack(approvedItems: [Int]) -> [WriteOutcome] {
        guard let judgment = lastJudgment, judgment.isConfident,
              let projectPath = judgment.match.projectPath else { return [] }
        let changes = WriteBackRouter.plan(judgment: judgment, approvedItems: approvedItems)
        let engine = WriteBackEngine(projectRoot: URL(filePath: projectPath))
        let outcomes = engine.apply(changes.map { engine.preview($0) })
        // Record the outcomes inside the encrypted session archive.
        if let directory = sessionDirectory, let encryption {
            let archiveURL = directory.appendingPathComponent("session.enc")
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
            if let title = lastMeetingTitle {
                filingMemory?.rememberMeeting(title, project: projectPath)
            }
            if let vector = lastTranscriptVector {
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
                    await stopCaptureThenTranscribe()
                }
            }
        case .stopped(let reason):
            // Auto-stop (target quit, device loss, failure) while recording.
            if state == .recording, apply(.captureStopped) {
                if case .failed(let failure) = reason {
                    _ = apply(.transcriptionFailed("Capture failed: \(failure)"))
                    return
                }
                await transcribeCurrentSession()
            }
        case .systemAudioPermissionSuspected:
            Self.log.warning("system lane all-zero — System Audio Recording grant suspected missing")
        default:
            break
        }
    }

    private func stopAndProcess() async {
        await stopCaptureThenTranscribe()
    }

    private func stopCaptureThenTranscribe() async {
        guard let session = captureSession else { return }
        do {
            _ = try await session.stop()
        } catch {
            Self.log.error("stop failed: \(error, privacy: .public)")
        }
        await transcribeCurrentSession()
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
            callCalendarContext = calendar

            await runPipeline(
                micWAV: imported.micWAV,
                systemWAV: imported.systemWAV,
                duration: imported.duration,
                directory: directory)
        } catch {
            processingDetail = ""
            _ = apply(.transcriptionFailed(Self.describe(error)))
        }
    }

    // MARK: - Processing

    private func transcribeCurrentSession() async {
        guard case .processing = state,
              let session = captureSession,
              let result = await session.result,
              let directory = sessionDirectory else { return }
        captureSession = nil
        eventTask?.cancel()
        eventTask = nil
        levels = nil
        await runPipeline(
            micWAV: result.micFileURL,
            systemWAV: result.systemFileURL,
            duration: result.duration,
            directory: directory)
    }

    /// The shared pipeline tail for live calls and imports: transcribe the
    /// lane(s), merge, match, judge, seal, and hand off to review. A nil
    /// `micWAV` (mono import) yields a single unattributed lane.
    private func runPipeline(
        micWAV: URL?, systemWAV: URL, duration: TimeInterval, directory: URL
    ) async {
        do {
            processingDetail = "Preparing models…"
            let modelURL = try await modelManager.ensure(.largeV3Turbo) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.processingDetail =
                        "Downloading model \(Int(progress.fraction * 100))% (one-time, 1.6 GB)"
                }
            }
            let vadURL = try await modelManager.ensure(.sileroVAD)

            if cachedTranscriber == nil {
                processingDetail = "Loading model…"
                cachedTranscriber = try WhisperTranscriber(modelPath: modelURL, vadModelPath: vadURL)
            }
            guard let transcriber = cachedTranscriber else { return }

            // Custom vocabulary + calendar terms pre-warm Whisper's proper
            // nouns. Project-scoped vocabulary applies when the learned
            // meeting link already names the project (matching happens
            // after transcription, so this is the only pre-hoc hint).
            var vocabularySources = [promptStore?.text(.vocabulary, scope: .global)]
            if let title = callCalendarContext?.title,
               let linked = filingMemory?.projectPath(forMeeting: title) {
                vocabularySources.append(
                    promptStore?.text(.vocabulary, scope: .project(path: linked)))
            }
            vocabularySources.append(promptStore?.text(.vocabulary, scope: .nextCall))
            let customTerms = PromptResolver.vocabularyTerms(vocabularySources)
            let bias = VocabularyBias.initialPrompt(
                terms: customTerms + (callCalendarContext?.signalTerms ?? []))
            let transcript: Transcript
            if let micWAV {
                processingDetail = "Transcribing your side…"
                let mic = try await transcriber.transcribe(
                    wavFile: micWAV, initialPrompt: bias)
                processingDetail = "Transcribing their side…"
                let system = try await transcriber.transcribe(
                    wavFile: systemWAV, initialPrompt: bias)
                transcript = TranscriptMerger.merge(mic: mic, system: system)
            } else {
                processingDetail = "Transcribing…"
                let single = try await transcriber.transcribe(
                    wavFile: systemWAV, initialPrompt: bias)
                transcript = TranscriptMerger.merge(
                    mic: ChannelTranscription(segments: [], language: single.language),
                    system: single)
            }

            // Phase-5 shortlist: cheap prefilter over every installed
            // agent's memory (Claude Code's store, Codex's sessions),
            // persisted beside the transcript for the judgment.
            processingDetail = "Matching projects…"
            let installed = agentRegistry.installedProviders()
            let candidates = AgentRegistry.mergedCandidates(
                from: installed.map { $0.knownProjects() })
            // Hybrid retrieval: keyword + calendar (in the prefilter),
            // learned meeting links, and call-vector similarity as boosts.
            let transcriptVector = TranscriptEmbedder.vector(for: transcript)
            lastTranscriptVector = transcriptVector
            lastMeetingTitle = callCalendarContext?.title
            var boosts: [String: Double] = [:]
            let mappedPath = callCalendarContext.flatMap {
                filingMemory?.projectPath(forMeeting: $0.title)
            }
            if let mappedPath { boosts[mappedPath, default: 0] += 8 }
            if let transcriptVector,
               let similarities = filingMemory?.similarities(to: transcriptVector) {
                for (path, similarity) in similarities where similarity > 0.6 {
                    boosts[path, default: 0] += (similarity - 0.6) / 0.4 * 4
                }
            }
            lastMatches = Prefilter.rank(
                candidates: candidates, transcript: transcript,
                calendar: callCalendarContext, boosts: boosts)
            // Stage 2: the routed agent's read-only judgment over the
            // shortlist. The project's provenance picks the agent, the user
            // default breaks ties, and every other installed agent is
            // automatic fallback. Failures degrade gracefully — the
            // transcript always survives, unfiled.
            lastJudgment = nil
            if !lastMatches.isEmpty, !transcript.segments.isEmpty {
                let filing = FilingPreferences.fromDefaults()
                let attempts = agentRegistry.attemptOrder(
                    topCandidateKnownTo: lastMatches.first?.candidate.knownTo ?? [],
                    preferred: filing.preferredAgent,
                    from: installed)
                if attempts.isEmpty {
                    Self.log.info("no coding agent installed — keeping transcript unfiled")
                }
                // Escalation gate: decisive local evidence pins the project
                // and the agent only extracts; uncertainty pays for the
                // full judgment.
                let calendarAgrees = lastMatches.first.map {
                    EscalationGate.calendarAgrees(callCalendarContext, with: $0.candidate)
                } ?? false
                let decision = EscalationGate.decide(
                    ranked: lastMatches,
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
                let shortlist = lastMatches.map {
                    (path: $0.candidate.path.path,
                     name: $0.candidate.name,
                     score: $0.score)
                }
                let provenance = Dictionary(
                    uniqueKeysWithValues: lastMatches.map {
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
                            project: (pinnedProject ?? lastMatches.first?.candidate.path.path)
                                .map { URL(filePath: $0).lastPathComponent },
                            attendees: callCalendarContext?.attendees ?? [],
                            date: sessionStartedAt)
                    }
                }
                for provider in attempts {
                    processingDetail = pinnedProject == nil
                        ? "Asking \(provider.displayName)…"
                        : "Extracting with \(provider.displayName)…"
                    do {
                        var judgment = try await provider.judge(
                            transcript: transcript,
                            shortlist: shortlist,
                            provenance: provenance,
                            calendar: callCalendarContext,
                            pinnedProject: pinnedProject,
                            instructions: instructions,
                            model: filing.modelIntent,
                            timeout: .seconds(240))
                        judgment.filedBy = provider.id.rawValue
                        lastJudgment = judgment
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
            processingDetail = "Securing…"
            let archive = SessionArchive(
                transcript: transcript,
                calendar: callCalendarContext,
                matches: lastMatches,
                judgment: lastJudgment)
            var audioRetained = true
            if let encryption {
                try encryption.encrypt(
                    archive, to: directory.appendingPathComponent("session.enc"))
                if retention.autoDeleteAudioAfterTranscription {
                    if let micWAV { try? FileManager.default.removeItem(at: micWAV) }
                    try? FileManager.default.removeItem(at: systemWAV)
                    audioRetained = false
                }
            } else {
                // No keychain key (should not happen): keep nothing on disk
                // rather than write plaintext content.
                Self.log.error("encryption unavailable — session content not persisted")
            }
            let recordID = UUID()
            currentRecordID = recordID
            try? await store?.insert(SessionStore.Row(
                id: recordID,
                startedAt: sessionStartedAt,
                duration: duration,
                directoryPath: directory.path,
                projectPath: lastJudgment?.match.projectPath,
                confidence: lastJudgment?.match.confidence,
                callType: lastJudgment?.callType,
                audioRetained: audioRetained,
                status: "review"))
            processingDetail = ""
            if apply(.transcriptReady(transcript)) {
                onReview?(transcript)
            }
        } catch {
            processingDetail = ""
            _ = apply(.transcriptionFailed(Self.describe(error)))
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
