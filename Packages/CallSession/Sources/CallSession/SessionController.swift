import AnthropicKit
import AppKit
import AudioCapture
import CalendarContext
import Copilot
import Core
import Foundation
import Observation
import Persistence
import Transcription
import os

/// Runs one call at a time: finds the call audio, captures both sides,
/// streams them into live transcription, drives the copilot, then seals the
/// session and writes the summary in the background. The capture never
/// depends on transcription or Claude: either can fail quietly.
@MainActor
@Observable
public final class SessionController {

    public enum Phase: Equatable, Sendable {
        case idle
        /// Finding the call and starting capture.
        case starting
        case live
        /// Capture stopped; finalizing the transcript and sealing.
        case finishing
        case failed(String)
    }

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "Session")

    // MARK: Live state

    public private(set) var phase: Phase = .idle
    public private(set) var transcript = LiveTranscript()
    public private(set) var levels: CaptureLevels?
    /// Seconds since capture started (the transcript's timeline).
    public private(set) var callTime: TimeInterval = 0
    public private(set) var startedAt: Date?
    public private(set) var copilot: CopilotEngine?
    public private(set) var playbook: Playbook = .general
    public private(set) var context = SessionContext()
    /// The app whose audio is the "Them" lane.
    public private(set) var appName: String?
    /// Why live transcription is degraded, if it is.
    public private(set) var transcriptionNote: String?
    /// Why the copilot is off (no API key), if it is.
    public private(set) var copilotOffReason: String?
    public private(set) var micMuted = false
    /// The mic keeps hearing the other side: likely laptop speakers.
    public private(set) var onSpeakers = false
    public private(set) var silencePromptVisible = false

    // MARK: After the call

    /// Sessions whose summary is being written: id → status.
    public private(set) var summarizing: [UUID: String] = [:]
    public private(set) var summaryFailures: [UUID: String] = [:]
    /// Imports in flight: id → status.
    public private(set) var imports: [UUID: String] = [:]
    public private(set) var importFailure: String?
    /// The newest finished session with its summary (the island's peek).
    public private(set) var readySummary: SessionIndexEntry?

    /// Called whenever a session is saved or updated (library refresh).
    @ObservationIgnored public var onLibraryChange: (@MainActor () -> Void)?

    // MARK: Dependencies

    public let library: SessionLibrary
    @ObservationIgnored private let client: AnthropicClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connection: RelayConnectionStore
    @ObservationIgnored private let calendar = CalendarReader()
    /// Current playbooks (the app rebinds this once its model exists).
    @ObservationIgnored public var playbookProvider: @MainActor () -> PlaybookLibrary

    // MARK: Internals

    @ObservationIgnored private var capture: CaptureSession?
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private var folder: (name: String, url: URL)?
    @ObservationIgnored private var feeder: Task<Void, Never>?
    @ObservationIgnored private var eventsConsumer: Task<Void, Never>?
    @ObservationIgnored private var captureEvents: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var watchdog = SilenceWatchdog()
    @ObservationIgnored private var playbookChosenByUser = false
    @ObservationIgnored private var ending = false

    public init(
        library: SessionLibrary,
        client: AnthropicClient = .relay(),
        connection: RelayConnectionStore = .shared,
        defaults: UserDefaults = .standard,
        playbooks: @escaping @MainActor () -> PlaybookLibrary
    ) {
        self.library = library
        self.client = client
        self.connection = connection
        self.defaults = defaults
        self.playbookProvider = playbooks
    }

    public var isLive: Bool { phase == .live }

    public var isBusy: Bool {
        switch phase {
        case .starting, .live, .finishing: true
        case .idle, .failed: false
        }
    }

    /// Claude is connected through the Saaa relay.
    public var hasAPIKey: Bool { connection.isConnected }

    // MARK: - Start / stop

    /// The global hotkey and the island's record control.
    public func toggle() {
        switch phase {
        case .idle, .failed: start()
        case .live: stop()
        case .starting, .finishing: break
        }
    }

    /// Starts a session. `playbook` nil uses the default (or the one the
    /// calendar title matches); `context` pre-fills the copilot.
    public func start(playbook chosen: Playbook? = nil, context provided: SessionContext? = nil) {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        phase = .starting
        let library = playbookProvider()
        playbook = chosen ?? library.defaultPlaybook
        playbookChosenByUser = chosen != nil
        context = provided ?? SessionContext()
        transcript = LiveTranscript(language: SaaaSettings.locale(defaults).language.languageCode?.identifier ?? "en")
        levels = nil
        callTime = 0
        transcriptionNote = nil
        copilotOffReason = nil
        micMuted = false
        onSpeakers = false
        silencePromptVisible = false
        watchdog = SilenceWatchdog()
        ending = false
        Task { await begin(library: library) }
    }

    /// Stops the session and seals it.
    public func stop() {
        guard phase == .live else { return }
        phase = .finishing
        Task { await end() }
    }

    public func setMicMuted(_ muted: Bool) {
        micMuted = muted
        capture?.setMicMuted(muted)
    }

    public func dismissSilencePrompt() {
        watchdog.dismissPrompt()
        silencePromptVisible = false
    }

    public func clearFailure() {
        if case .failed = phase { phase = .idle }
        importFailure = nil
    }

    /// Prep edits during a call reach the copilot immediately.
    public func updateContext(_ newContext: SessionContext) {
        context = newContext
        copilot?.context = newContext
    }

    /// Switches playbooks mid-call (quick actions and prompt change at once).
    public func switchPlaybook(_ newPlaybook: Playbook) {
        playbook = newPlaybook
        playbookChosenByUser = true
        copilot?.playbook = newPlaybook
        copilot?.autoSuggestEnabled = newPlaybook.autoSuggest
        copilot?.liveNotesEnabled = newPlaybook.liveNotes
    }

    public func dismissReadySummary() {
        readySummary = nil
    }

    // MARK: - Begin

    private func begin(library: PlaybookLibrary) async {
        guard let target = Self.resolveTarget() else {
            phase = .failed("No call audio found. Join the call first, then start Saaa.")
            return
        }
        appName = target.name

        // Calendar context and playbook pick, before vocabulary is fixed.
        if CalendarReader.hasAccess, let event = await calendar.eventOverlapping() {
            context = context.filling(from: SessionContext.from(event))
            if !playbookChosenByUser, let matched = PlaybookMatcher.match(title: event.title, in: library.all) {
                playbook = matched
            }
        }

        let started = Date()
        let folder: (name: String, url: URL)
        do {
            folder = try await self.library.makeFolder(startedAt: started)
        } catch {
            phase = .failed("Couldn't create the session folder.")
            return
        }
        self.folder = folder

        let session = CaptureSession(configuration: CaptureConfiguration(
            target: .process(target.pid), outputDirectory: folder.url))
        capture = session
        captureEvents = Task { [weak self] in
            for await event in session.events {
                self?.handleCapture(event)
            }
        }

        // Live transcription starts alongside capture; audio queues in the
        // stream until the analyzers are ready.
        let transcriber = LiveTranscriber()
        self.transcriber = transcriber
        let locale = SaaaSettings.locale(defaults)
        let vocabulary = playbook.vocabulary + context.vocabularyHints
        let ready = Task { () -> String? in
            do {
                try await transcriber.start(locale: locale, vocabulary: vocabulary)
                return nil
            } catch {
                return "Live transcript unavailable (\(Self.describe(error)))."
            }
        }
        feeder = Task.detached {
            let failure = await ready.value
            for await chunk in session.liveAudio where failure == nil {
                transcriber.append(chunk.lane == .mic ? .me : .them, samples: chunk.samples, startFrame: chunk.startFrame)
            }
            if failure == nil {
                await transcriber.finish()
            } else {
                await transcriber.cancel()
            }
        }
        eventsConsumer = Task { [weak self] in
            for await event in transcriber.events {
                self?.apply(event)
            }
        }
        Task { [weak self] in
            if let failure = await ready.value { self?.transcriptionNote = failure }
        }

        do {
            try await session.start()
        } catch {
            capture = nil
            await transcriber.cancel()
            feeder?.cancel()
            cleanUpTasks()
            try? FileManager.default.removeItem(at: folder.url)
            self.folder = nil
            phase = .failed(Self.describe(error))
            return
        }
        startedAt = started
        phase = .live
        Self.log.info("session live (\(self.playbook.id, privacy: .public))")

        if connection.isConnected {
            let engine = CopilotEngine(
                playbook: playbook, context: context, service: client, defaults: defaults,
                transcript: { [weak self] in self?.transcript ?? LiveTranscript() },
                callTime: { [weak self] in self?.callTime ?? 0 })
            copilot = engine
            engine.prewarm()
        } else {
            copilotOffReason = "Connect Claude in Settings to get live answers."
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.copilot?.tick()
            }
        }
    }

    // MARK: - Feeds

    private func apply(_ event: LiveTranscriber.Event) {
        if case .laneFailed(let lane, _) = event {
            transcriptionNote = "\(lane.label) transcript paused. Recording continues."
            return
        }
        let outcome = transcript.apply(event)
        if let entry = outcome?.added {
            copilot?.handleCommitted(entry)
        }
    }

    private func handleCapture(_ event: CaptureEvent) {
        switch event {
        case .levels(let reading):
            levels = reading
            // Whole seconds: everything showing the clock redraws once a second, not ten times.
            let seconds = reading.time.rounded(.down)
            if seconds != callTime { callTime = seconds }
            if !onSpeakers, (transcriber?.echoFilteredSeconds ?? 0) > 10 {
                onSpeakers = true
            }
            switch watchdog.feed(mic: reading.mic.rms, system: reading.system.rms, at: reading.time) {
            case .quiet:
                if silencePromptVisible { silencePromptVisible = false }
            case .prompt:
                silencePromptVisible = true
            case .timedOut:
                silencePromptVisible = false
                stop()
            }
        case .stopped:
            // The call app quit or the device vanished: seal what we have.
            if phase == .live {
                phase = .finishing
                Task { await end() }
            }
        case .systemAudioPermissionSuspected:
            transcriptionNote = "Saaa can't hear the other side. Check System Audio Recording in System Settings."
        default:
            break
        }
    }

    // MARK: - End

    private func end() async {
        guard !ending else { return }
        ending = true
        let result = try? await capture?.stop()
        // liveAudio ends after the final drain → the feeder finalizes the
        // transcriber → its events end → the consumer returns.
        await feeder?.value
        await eventsConsumer?.value
        captureEvents?.cancel()
        ticker?.cancel()
        let sealed = copilot?.finish()
        transcript.clearPartials()

        let keepAudio = SaaaSettings.keepsAudio(defaults)
        let record = SessionRecord(
            startedAt: startedAt ?? .now,
            duration: result?.duration ?? callTime,
            title: context.title,
            playbookID: playbook.id,
            playbookName: playbook.name,
            context: context,
            transcript: transcript.transcript,
            thread: sealed?.thread ?? [],
            notes: sealed?.notes,
            usage: sealed?.ledger ?? UsageLedger(),
            source: .live,
            audioRetained: keepAudio)
        if let folder {
            do {
                try await library.save(record, folder: folder.name)
                onLibraryChange?()
            } catch {
                Self.log.error("seal failed: \(String(describing: error), privacy: .public)")
            }
            if !keepAudio {
                for name in ["mic.wav", "system.wav"] {
                    try? FileManager.default.removeItem(at: folder.url.appendingPathComponent(name))
                }
            }
        }
        cleanUpTasks()
        capture = nil
        transcriber = nil
        copilot = nil
        folder = nil
        levels = nil
        phase = .idle
        Self.log.info("session sealed")

        if SaaaSettings.autoSummary(defaults), connection.isConnected, !record.transcript.segments.isEmpty {
            summarize(record)
        }
    }

    private func cleanUpTasks() {
        feeder = nil
        eventsConsumer = nil
        captureEvents?.cancel()
        captureEvents = nil
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Summary

    /// Writes (or rewrites) the summary for a sealed session.
    public func summarize(_ record: SessionRecord) {
        guard summarizing[record.id] == nil else { return }
        summarizing[record.id] = "Writing summary…"
        summaryFailures[record.id] = nil
        let library = self.library
        let service = SummaryService(service: client)
        let playbook = playbookProvider().playbook(id: record.playbookID) ?? .general
        let model = ModelRole.summary.modelID(defaults: defaults)
        Task { [weak self] in
            do {
                let (summary, usage) = try await service.summarize(
                    playbook: playbook, context: record.context, transcript: record.transcript,
                    notes: record.notes, thread: record.thread, startedAt: record.startedAt,
                    duration: record.duration, model: model)
                var updated = (try? await library.record(record.id)) ?? record
                updated.summary = summary
                updated.usage.add(usage)
                let entry = try await library.update(updated)
                self?.summarizing[record.id] = nil
                self?.readySummary = entry
                self?.onLibraryChange?()
            } catch {
                self?.summarizing[record.id] = nil
                self?.summaryFailures[record.id] =
                    (error as? AnthropicError)?.userMessage ?? "The summary couldn't be written."
            }
        }
    }

    // MARK: - Import

    /// Runs an existing recording through transcription and summary.
    public func importRecording(_ url: URL, playbook chosen: Playbook? = nil, context provided: SessionContext? = nil) {
        let id = UUID()
        imports[id] = "Preparing \(url.lastPathComponent)…"
        importFailure = nil
        let library = self.library
        let locale = SaaaSettings.locale(defaults)
        let playbook = chosen ?? playbookProvider().defaultPlaybook
        Task { [weak self] in
            do {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
                let folder = try await library.makeFolder(startedAt: created, suffix: "import")
                let imported = try await MediaImporter.extract(from: url, into: folder.url)
                var transcript = LiveTranscript()
                let vocabulary = playbook.vocabulary + (provided?.vocabularyHints ?? [])
                if let mic = imported.micWAV {
                    self?.imports[id] = "Transcribing your side…"
                    let segments = try await FileTranscriber.transcribe(
                        wav: mic, lane: .me, locale: locale, vocabulary: vocabulary)
                    for segment in segments {
                        transcript.commit(.me, start: segment.start, end: segment.end, text: segment.text)
                    }
                }
                self?.imports[id] = imported.micWAV == nil ? "Transcribing…" : "Transcribing their side…"
                let segments = try await FileTranscriber.transcribe(
                    wav: imported.systemWAV, lane: .them, locale: locale, vocabulary: vocabulary)
                for segment in segments {
                    transcript.commit(.them, start: segment.start, end: segment.end, text: segment.text)
                }
                var context = provided ?? SessionContext()
                if context.title.isEmpty { context.title = url.deletingPathExtension().lastPathComponent }
                let record = SessionRecord(
                    startedAt: created, duration: imported.duration, title: context.title,
                    playbookID: playbook.id, playbookName: playbook.name, context: context,
                    transcript: transcript.transcript, source: .imported)
                try await library.save(record, folder: folder.name)
                for wav in [imported.micWAV, imported.systemWAV].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(at: wav)
                }
                self?.imports[id] = nil
                self?.onLibraryChange?()
                if let self, self.connection.isConnected, !record.transcript.segments.isEmpty {
                    self.summarize(record)
                }
            } catch {
                self?.imports[id] = nil
                Self.log.error("import failed: \(String(describing: error), privacy: .public)")
                self?.importFailure = "\(url.lastPathComponent) couldn't be imported (\(Self.describe(error)))."
            }
        }
    }

    // MARK: - Helpers

    /// The conferencing app (or browser) whose audio is the other side.
    static func resolveTarget() -> TargetPicker.Candidate? {
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

    nonisolated static func describe(_ error: Error) -> String {
        if let captureError = error as? CaptureError {
            switch captureError {
            case .microphonePermissionDenied:
                return "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            case .systemAudioPermissionDenied:
                return "System Audio Recording is off. Add Saaa under System Settings › Privacy & Security › Screen & System Audio Recording."
            case .targetProcessNotFound:
                return "The call app stopped playing audio."
            default:
                return String(describing: captureError)
            }
        }
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .unsupportedLanguage(let id): return "\(id) isn't supported for on-device transcription"
            case .engineUnavailable(let detail), .audioUnreadable(let detail): return detail
            }
        }
        if let mediaError = error as? MediaImportError {
            switch mediaError {
            case .unsupportedType: return "unsupported file type"
            case .noAudioTrack: return "no audio track"
            case .unreadable(let detail): return detail
            }
        }
        return error.localizedDescription
    }
}
