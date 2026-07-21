import CoreAudio
import Foundation

/// Which capture implementation a session used.
public enum CaptureBackend: Sendable, Equatable {
    /// Core Audio process tap inside a private aggregate device (primary).
    case processTap
    /// ScreenCaptureKit app-filtered audio + microphone stream (fallback).
    case screenCaptureKit
}

/// What the system ("Them") lane records.
public enum CaptureTarget: Sendable, Equatable {
    /// One app's audio — the given PID plus every descendant helper process
    /// that is a Core Audio client (browsers and some conferencing apps emit
    /// audio from helpers, not the app process itself).
    case process(pid_t)
    /// Everything the system plays (global tap). Debug/diagnostic target; no
    /// ScreenCaptureKit fallback and no process-exit auto-stop.
    case allSystemAudio
}

/// Immutable description of one capture run.
public struct CaptureConfiguration: Sendable {
    /// What the system lane records.
    public var target: CaptureTarget
    /// Microphone device; `nil` uses the default input at `start()`.
    public var micDeviceID: AudioObjectID?
    /// Directory receiving `mic.wav` and `system.wav` (created if missing).
    public var outputDirectory: URL
    /// Force a backend; `nil` tries the process tap, falling back to
    /// ScreenCaptureKit if tap setup fails.
    public var preferredBackend: CaptureBackend?

    public init(
        target: CaptureTarget,
        outputDirectory: URL,
        micDeviceID: AudioObjectID? = nil,
        preferredBackend: CaptureBackend? = nil
    ) {
        self.target = target
        self.outputDirectory = outputDirectory
        self.micDeviceID = micDeviceID
        self.preferredBackend = preferredBackend
    }
}

/// Paired Me/Them meter reading, emitted ~10 Hz while recording.
public struct CaptureLevels: Sendable, Equatable {
    /// The user's microphone — the "Me" meter.
    public let mic: AudioLevels
    /// The tapped process's output — the "Them" meter.
    public let system: AudioLevels
    /// Seconds of audio recorded so far.
    public let time: TimeInterval

    public init(mic: AudioLevels, system: AudioLevels, time: TimeInterval) {
        self.mic = mic
        self.system = system
        self.time = time
    }
}

/// A typed, comparable description of a mid-run failure.
public struct CaptureFailure: Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let detail: String

    public init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }

    public var description: String { "\(code): \(detail)" }
}

/// Why a capture session ended.
public enum CaptureStopReason: Sendable, Equatable {
    /// `stop()` was called.
    case requested
    /// The tapped process exited — the Phase-4 auto-stop trigger.
    case targetProcessExited
    /// Unrecoverable device loss (e.g. every input device vanished).
    case deviceInvalidated(String)
    /// The OS revoked or declined a permission mid-run.
    case permissionRevoked
    /// Any other terminal failure.
    case failed(CaptureFailure)
}

/// Events published by ``CaptureSession/events``.
public enum CaptureEvent: Sendable {
    /// Meter update, ~10 Hz.
    case levels(CaptureLevels)
    /// The tapped process started/stopped emitting audio (debounced ~2 s).
    /// Informational only — never an auto-stop signal.
    case targetIdleChanged(Bool)
    /// The system default input changed; capture stays pinned to its mic.
    case defaultInputChanged
    /// A device or format change forced a teardown + re-setup; a silence gap
    /// keeps both WAV timelines aligned.
    case rebuilding(reason: String)
    /// The system lane has been exact-zero since the start — likely a denied
    /// System Audio Recording grant (there is no API to query it).
    case systemAudioPermissionSuspected
    /// Ring-buffer overrun deltas (should never fire; treated as a bug signal).
    case samplesDropped(mic: Int, system: Int)
    /// Terminal — always the last event on the stream.
    case stopped(CaptureStopReason)
}

/// What a finished session produced.
public struct RecordingResult: Sendable {
    /// 16 kHz / mono / 16-bit PCM WAV of the user's microphone.
    public let micFileURL: URL
    /// 16 kHz / mono / 16-bit PCM WAV of the tapped process, sample-aligned
    /// to the mic file.
    public let systemFileURL: URL
    /// Seconds of audio in each file.
    public let duration: TimeInterval
    public let backendUsed: CaptureBackend
    public let stopReason: CaptureStopReason
    public let droppedSamples: (mic: Int, system: Int)
}

/// Errors thrown by ``CaptureSession/start()`` and ``CaptureSession/stop()``.
public enum CaptureError: Error {
    case microphonePermissionDenied
    case systemAudioPermissionDenied(OSStatus?)
    case screenRecordingPermissionDenied
    /// The PID has no Core Audio client object (app not using audio).
    case targetProcessNotFound(pid_t)
    /// No usable microphone device exists.
    case micDeviceUnavailable
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    /// The aggregate's input streams could not be attributed to mic vs tap.
    case layoutAmbiguous
    case unsupportedTapFormat
    case notRunning
    case alreadyRunning
    /// The requested backend cannot serve this target (e.g. ScreenCaptureKit
    /// has no global-audio mode in Saaa; `.allSystemAudio` is tap-only).
    case backendUnavailable
    case fileError(underlying: Error)
}
