import AVFoundation
import AppKit
import CoreAudio
import Foundation
import os

/// One capture session == one pair of WAV files. Create a fresh instance per
/// recording.
///
/// Drives the primary process-tap path (``ProcessTapEngine``) with automatic
/// fallback to ScreenCaptureKit (``SCKEngine``), owns the drain task that
/// turns ring content into two aligned 16 kHz mono WAVs, publishes
/// ``CaptureEvent``s, and performs auto-stop when the target process exits.
public actor CaptureSession {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "CaptureSession")

    private let configuration: CaptureConfiguration

    /// Event feed. Single-consumer; safe to subscribe before `start()`.
    /// Ends with `.stopped` after a successful start; a failed `start()`
    /// finishes the stream without one.
    public nonisolated let events: AsyncStream<CaptureEvent>
    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation

    // Shared with the RT/handler threads.
    private let micRing = RingBuffer(minimumCapacity: 1 << 19)
    private let sysRing = RingBuffer(minimumCapacity: 1 << 19)
    private let micGap = SilenceGapBox()
    private let sysGap = SilenceGapBox()
    private let micFormatBox = LaneFormatBox()
    private let sysFormatBox = LaneFormatBox()
    private let anchor = HostTimeAnchor()
    private let stopFlag = StopFlag()
    /// Raw (undebounced) 'piro' state — gates the permission heuristic.
    private let targetOutputActive = BoolBox()

    private var tapEngine: ProcessTapEngine?
    private var sckEngine: SCKEngine?
    private var backend: CaptureBackend = .processTap
    private var drainTask: Task<DrainSummary, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var idleDebounceTask: Task<Void, Never>?
    private var starting = false
    private var running = false
    private var stopping = false
    private var finalizeTask: Task<RecordingResult, Never>?
    /// Engine setup breadcrumbs, captured before teardown for diagnostics.txt.
    private var tapEngineDiagnostics: [String]?

    /// Non-nil once the session has ended for any reason (auto-stop included).
    public private(set) var result: RecordingResult?

    public var isRunning: Bool { running }

    public init(configuration: CaptureConfiguration) {
        self.configuration = configuration
        (events, eventContinuation) = AsyncStream.makeStream(
            of: CaptureEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    // MARK: - Start

    /// Full setup (contract §2) + begins recording. Throws `CaptureError`;
    /// nothing persists on throw and the event stream is finished.
    public func start() async throws {
        // `starting` closes the reentrancy window across the awaits below —
        // without it two concurrent starts would both pass this guard.
        guard !running, !starting, result == nil else { throw CaptureError.alreadyRunning }
        starting = true
        defer { starting = false }

        do {
            // Setup step 1 — mic TCC preflight, before touching the HAL.
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CaptureError.microphonePermissionDenied
            }

            do {
                try FileManager.default.createDirectory(
                    at: configuration.outputDirectory, withIntermediateDirectories: true)
            } catch {
                throw CaptureError.fileError(underlying: error)
            }

            switch configuration.preferredBackend {
            case .screenCaptureKit:
                try await startSCK()
            case .processTap:
                try startTap()
            case nil:
                do {
                    try startTap()
                } catch let error as CaptureError {
                    switch error {
                    case .tapCreationFailed, .aggregateCreationFailed, .ioProcFailed,
                         .layoutAmbiguous, .unsupportedTapFormat:
                        guard case .process = configuration.target else { throw error }
                        Self.log.warning("tap path failed (\(String(describing: error), privacy: .public)); falling back to ScreenCaptureKit")
                        try await startSCK()
                    default:
                        throw error
                    }
                }
            }
        } catch {
            // The session is unusable — release any subscriber.
            eventContinuation.finish()
            throw error
        }

        startDrainTask()
        running = true
    }

    private func startTap() throws {
        let engine = ProcessTapEngine(
            target: configuration.target,
            micRing: micRing, sysRing: sysRing, anchor: anchor)
        try engine.setup(preferredMicDeviceID: configuration.micDeviceID) { [weak self] signal in
            guard let self else { return }
            Task { await self.handle(signal) }
        }
        guard let layout = engine.layout else { throw CaptureError.layoutAmbiguous }
        micFormatBox.publish(LaneFormat(channels: layout.micChannels, sampleRate: layout.micSampleRate))
        sysFormatBox.publish(LaneFormat(channels: layout.tapChannels, sampleRate: layout.tapSampleRate))
        tapEngine = engine
        backend = .processTap
        if case .allSystemAudio = configuration.target {
            // No 'piro' listener exists for a global tap; arm the all-zero
            // permission heuristic unconditionally (system audio is always
            // "active enough" system-wide during a debug capture).
            targetOutputActive.set(true)
        }
    }

    private func startSCK() async throws {
        guard case .process(let targetPID) = configuration.target else {
            throw CaptureError.backendUnavailable
        }
        let engine = SCKEngine(
            targetPID: targetPID,
            micRing: micRing, sysRing: sysRing,
            micGap: micGap, sysGap: sysGap,
            micFormatBox: micFormatBox, sysFormatBox: sysFormatBox
        ) { [weak self] reason in
            guard let self else { return }
            Task { await self.autoStop(reason: reason) }
        }
        try await engine.start()
        sckEngine = engine
        backend = .screenCaptureKit

        // SCK has no HAL process object — watch NSWorkspace for target exit.
        let pid = targetPID
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == pid else { return }
            Task { await self.autoStop(reason: .targetProcessExited) }
        }
    }

    // MARK: - Drain task

    private struct DrainSummary {
        var duration: TimeInterval = 0
        var failure: CaptureFailure?
        var laneStats: String = "no pipelines materialized"
    }

    private func startDrainTask() {
        let micURL = configuration.outputDirectory.appendingPathComponent("mic.wav")
        let sysURL = configuration.outputDirectory.appendingPathComponent("system.wav")
        let micRing = micRing, sysRing = sysRing
        let micGap = micGap, sysGap = sysGap
        let micFormatBox = micFormatBox, sysFormatBox = sysFormatBox
        let stopFlag = stopFlag
        let continuation = eventContinuation
        let backend = backend
        let targetOutputActive = targetOutputActive
        // A drain failure must stop the whole session — without this the
        // session would keep "running" with a dead pipeline.
        let onFailure: @Sendable (CaptureFailure) -> Void = { [weak self] failure in
            guard let self else { return }
            Task { await self.autoStop(reason: .failed(failure)) }
        }

        drainTask = Task.detached(priority: .userInitiated) {
            var micPipe: LanePipeline?
            var sysPipe: LanePipeline?
            var summary = DrainSummary()
            var cycle = 0
            var suspectedEmitted = false

            func ensurePipelines() throws {
                if micPipe == nil, let format = micFormatBox.current {
                    micPipe = try LanePipeline(ring: micRing, gap: micGap, fileURL: micURL, format: format)
                }
                if sysPipe == nil, let format = sysFormatBox.current {
                    sysPipe = try LanePipeline(ring: sysRing, gap: sysGap, fileURL: sysURL, format: format)
                }
                if let pipe = micPipe, let format = micFormatBox.current, format != pipe.format {
                    try pipe.reconfigure(to: format)
                }
                if let pipe = sysPipe, let format = sysFormatBox.current, format != pipe.format {
                    try pipe.reconfigure(to: format)
                }
            }

            while !stopFlag.isRaised {
                try? await Task.sleep(for: .milliseconds(100))
                do {
                    try ensurePipelines()
                    // Lanes drain independently: on the SCK path the system
                    // lane's format arrives only with its first buffer, and a
                    // quiet target must not starve the mic lane.
                    let mic = try micPipe.map { try $0.drainCycle() }
                    let sys = try sysPipe.map { try $0.drainCycle() }
                    guard mic != nil || sys != nil else { continue }
                    continuation.yield(.levels(CaptureLevels(
                        mic: mic?.levels ?? .zero,
                        system: sys?.levels ?? .zero,
                        time: micPipe?.duration ?? sysPipe?.duration ?? 0)))
                    let dropped = (mic: mic?.droppedDelta ?? 0, sys: sys?.droppedDelta ?? 0)
                    if dropped.mic > 0 || dropped.sys > 0 {
                        continuation.yield(.samplesDropped(mic: dropped.mic, system: dropped.sys))
                    }
                    // Contract §7 case 7: only meaningful on the tap path and
                    // only while the target is actually emitting audio.
                    if !suspectedEmitted, backend == .processTap, targetOutputActive.get,
                       let sysPipe, sysPipe.allZeroSoFar, (micPipe?.duration ?? 0) > 3 {
                        suspectedEmitted = true
                        continuation.yield(.systemAudioPermissionSuspected)
                    }
                    cycle += 1
                    if cycle % 50 == 0 { // ~5 s: crash-resilience header patch
                        try? micPipe?.checkpoint()
                        try? sysPipe?.checkpoint()
                    }
                } catch {
                    summary.failure = CaptureFailure(
                        code: "drain", detail: String(describing: error))
                    onFailure(summary.failure!)
                    break
                }
            }

            // Final drain + converter EOS flush (mandatory) + header patch.
            do {
                if micPipe == nil {
                    // Format never arrived (e.g. instant stop): emit a valid
                    // empty WAV so the result's URLs always exist.
                    try? WavWriter(url: micURL).finish()
                }
                if sysPipe == nil {
                    try? WavWriter(url: sysURL).finish()
                }
                try micPipe?.finish()
                try sysPipe?.finish()
            } catch {
                if summary.failure == nil {
                    summary.failure = CaptureFailure(
                        code: "finalize", detail: String(describing: error))
                }
            }
            summary.duration = micPipe?.duration ?? 0
            func stats(_ pipe: LanePipeline?, _ label: String) -> String {
                guard let pipe else { return "\(label): never materialized" }
                return "\(label): \(String(format: "%.2f", pipe.duration))s, "
                    + "\(pipe.nonzeroChunkCount)/\(pipe.chunkCount) chunks with signal, "
                    + "format \(pipe.format.channels)ch@\(Int(pipe.format.sampleRate))"
            }
            summary.laneStats = stats(micPipe, "mic") + "\n" + stats(sysPipe, "sys")
            return summary
        }
    }

    // MARK: - Stop

    /// Graceful stop: teardown, converter EOS flush, WAV finalization.
    /// Idempotent — after (or during) auto-stop it returns that result.
    @discardableResult
    public func stop() async throws -> RecordingResult {
        if let result { return result }
        if let finalizeTask { return await finalizeTask.value }
        guard running else { throw CaptureError.notRunning }
        return await finalize(reason: .requested)
    }

    private func autoStop(reason: CaptureStopReason) async {
        guard running, finalizeTask == nil, result == nil else { return }
        _ = await finalize(reason: reason)
    }

    /// Exactly one finalization ever runs; concurrent stop/auto-stop callers
    /// all await the same task and observe the same result and reason.
    private func finalize(reason: CaptureStopReason) async -> RecordingResult {
        if let finalizeTask { return await finalizeTask.value }
        let task = Task { await performFinalize(reason: reason) }
        finalizeTask = task
        return await task.value
    }

    private func performFinalize(reason: CaptureStopReason) async -> RecordingResult {
        stopping = true
        idleDebounceTask?.cancel()

        // Stop producers first so the final drain sees every last sample.
        tapEngineDiagnostics = tapEngine?.diagnostics
        tapEngine?.teardown()
        tapEngine = nil
        if let sckEngine {
            await sckEngine.stop()
            self.sckEngine = nil
        }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }

        stopFlag.raise()
        let summary = await drainTask?.value ?? DrainSummary()
        drainTask = nil

        let finalReason: CaptureStopReason
        if let failure = summary.failure, case .requested = reason {
            finalReason = .failed(failure)
        } else {
            finalReason = reason
        }

        // Diagnostics file next to the WAVs — content-free (formats, counts,
        // stream topology; never audio or transcript data).
        let report = """
        Saaa capture diagnostics
        backend: \(backend)
        stop reason: \(finalReason)
        dropped: mic \(micRing.droppedSamples) sys \(sysRing.droppedSamples)
        \(summary.laneStats)
        --- engine setup:
        \((tapEngineDiagnostics ?? ["(none)"]).joined(separator: "\n"))
        """
        try? report.write(
            to: configuration.outputDirectory.appendingPathComponent("diagnostics.txt"),
            atomically: true, encoding: .utf8)

        let recording = RecordingResult(
            micFileURL: configuration.outputDirectory.appendingPathComponent("mic.wav"),
            systemFileURL: configuration.outputDirectory.appendingPathComponent("system.wav"),
            duration: summary.duration,
            backendUsed: backend,
            stopReason: finalReason,
            droppedSamples: (micRing.droppedSamples, sysRing.droppedSamples))
        result = recording
        running = false
        eventContinuation.yield(.stopped(finalReason))
        eventContinuation.finish()
        return recording
    }

    // MARK: - Signal handling (tap path)

    private func handle(_ signal: TapEngineSignal) async {
        guard running, !stopping else { return }
        switch signal {
        case .processListChanged:
            if tapEngine?.isTargetProcessAlive == false {
                await autoStop(reason: .targetProcessExited)
            }
        case .defaultInputChanged:
            // Capture stays pinned to the mic the aggregate was built around.
            eventContinuation.yield(.defaultInputChanged)
        case .targetRunningOutputChanged(let isRunning):
            targetOutputActive.set(isRunning)
            idleDebounceTask?.cancel()
            let continuation = eventContinuation
            idleDebounceTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                continuation.yield(.targetIdleChanged(!isRunning))
            }
        case .aggregateDied:
            await rebuild(reason: "capture device invalidated")
        case .compositionChanged:
            await rebuild(reason: "aggregate composition changed")
        case .sampleRateOrFormatChanged:
            await rebuild(reason: "sample rate or format changed")
        }
    }

    /// Full teardown + re-setup on device/format change (contract §7). The
    /// rings, writers, and drain task survive; the wall-clock gap becomes
    /// silence in BOTH files so the timelines stay sample-aligned.
    private func rebuild(reason: String) async {
        guard let engine = tapEngine, !stopping else { return }
        eventContinuation.yield(.rebuilding(reason: reason))
        let gapStart = ContinuousClock.now
        engine.teardown()

        // Let the drain task finish converting the pre-teardown backlog under
        // the OLD formats before any new-format samples can enter the rings
        // (bounded wait; the drain cadence is 100 ms).
        for _ in 0..<40 where micRing.count > 0 || sysRing.count > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }

        // The pinned mic may be gone — retry with it, then with the current
        // default input (case 4), before giving up.
        var lastError: CaptureError = .micDeviceUnavailable
        for micDevice in [configuration.micDeviceID, nil] {
            do {
                try engine.setup(preferredMicDeviceID: micDevice) { [weak self] signal in
                    guard let self else { return }
                    Task { await self.handle(signal) }
                }
                guard let layout = engine.layout else { throw CaptureError.layoutAmbiguous }
                // Gap silence first, then the new formats — the drain consumes
                // gaps at the start of each cycle, so this order keeps silence
                // ahead of any new-format audio in the files.
                let gap = gapStart.duration(to: .now)
                let gapSeconds = Double(gap.components.seconds)
                    + Double(gap.components.attoseconds) * 1e-18
                let gapFrames = Int(gapSeconds * LanePipeline.outputSampleRate)
                micGap.add(frames: gapFrames)
                sysGap.add(frames: gapFrames)
                micFormatBox.publish(LaneFormat(
                    channels: layout.micChannels, sampleRate: layout.micSampleRate))
                sysFormatBox.publish(LaneFormat(
                    channels: layout.tapChannels, sampleRate: layout.tapSampleRate))
                return
            } catch let error as CaptureError {
                lastError = error
                if case .targetProcessNotFound = error {
                    await autoStop(reason: .targetProcessExited)
                    return
                }
            } catch {
                lastError = .fileError(underlying: error)
            }
        }
        Self.log.error("rebuild failed: \(String(describing: lastError), privacy: .public)")
        await autoStop(reason: .deviceInvalidated(String(describing: lastError)))
    }
}
