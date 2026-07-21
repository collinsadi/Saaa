import AppKit
import AudioCapture
import CalendarContext
import ClaudeBridge
import Core
import Foundation
import Matching
import Observation
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
    /// Claude Code's judgment for the last processed call, if it ran.
    public private(set) var lastJudgment: CallJudgment?

    private let claudeCLI = ClaudeCLI()

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
            Self.log.info("ignored \(String(describing: event), privacy: .public) in \(String(describing: self.state), privacy: .public)")
            return false
        }
        Self.log.info("\(String(describing: self.state), privacy: .public) → \(String(describing: next), privacy: .public)")
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

    /// The review surface was closed.
    public func closeReview() {
        if apply(.reviewClosed) {
            apply(.reset)
        }
    }

    // MARK: - Recording

    private func startRecording() async {
        levels = nil
        silencePromptVisible = false
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

            // Calendar terms pre-warm Whisper's vocabulary (proper nouns).
            let bias = VocabularyBias.initialPrompt(
                terms: callCalendarContext?.signalTerms ?? [])
            processingDetail = "Transcribing your side…"
            let mic = try await transcriber.transcribe(
                wavFile: result.micFileURL, initialPrompt: bias)
            processingDetail = "Transcribing their side…"
            let system = try await transcriber.transcribe(
                wavFile: result.systemFileURL, initialPrompt: bias)

            let transcript = TranscriptMerger.merge(mic: mic, system: system)

            // Phase-5 shortlist: cheap prefilter over the local Claude store,
            // persisted beside the transcript for the Phase-6 judgment.
            processingDetail = "Matching projects…"
            let candidates = CandidateEnumerator().enumerate()
            lastMatches = Prefilter.rank(
                candidates: candidates, transcript: transcript,
                calendar: callCalendarContext)
            try Self.write(transcript, result: result, to: directory)
            try Self.writeMatching(
                matches: lastMatches, calendar: callCalendarContext, to: directory)

            // Stage 2: Claude Code's read-only judgment over the shortlist.
            // Failures degrade gracefully — the transcript always survives.
            lastJudgment = nil
            if !lastMatches.isEmpty, !transcript.segments.isEmpty {
                processingDetail = "Asking Claude Code…"
                do {
                    let judgment = try await MatchingJudge.judge(
                        cli: claudeCLI,
                        transcript: transcript,
                        shortlist: lastMatches.map {
                            (path: $0.candidate.path.path,
                             name: $0.candidate.name,
                             score: $0.score)
                        },
                        calendar: callCalendarContext)
                    lastJudgment = judgment
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(judgment)
                        .write(to: directory.appendingPathComponent("judgment.json"))
                } catch ClaudeBridgeError.claudeNotInstalled {
                    Self.log.info("claude not installed — keeping transcript unfiled")
                } catch {
                    Self.log.error("judgment failed: \(String(describing: error), privacy: .public)")
                }
            }
            processingDetail = ""
            if apply(.transcriptReady(transcript)) {
                onReview?(transcript)
            }
        } catch {
            processingDetail = ""
            _ = apply(.transcriptionFailed(Self.describe(error)))
        }
    }

    /// Persists transcript.md (human) + transcript.json (structured) beside
    /// the WAVs. (Encryption + retention arrive with the Persistence phase.)
    private static func write(
        _ transcript: Transcript, result: RecordingResult, to directory: URL
    ) throws {
        let header = """
        # Call transcript
        - duration: \(String(format: "%.1f", result.duration))s
        - language: \(transcript.language)
        - backend: \(result.backendUsed == .processTap ? "process tap" : "ScreenCaptureKit")

        """
        try (header + transcript.attributedText + "\n")
            .write(to: directory.appendingPathComponent("transcript.md"),
                   atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript)
            .write(to: directory.appendingPathComponent("transcript.json"))
    }

    /// Persists the prefilter shortlist + calendar snapshot (Phase-6 input).
    private static func writeMatching(
        matches: [ScoredCandidate], calendar: Core.CalendarContext?, to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(matches)
            .write(to: directory.appendingPathComponent("matches.json"))
        if let calendar {
            try encoder.encode(calendar)
                .write(to: directory.appendingPathComponent("calendar.json"))
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
