import Core
import Foundation
import Synchronization
import os
import whisper

/// One lane's transcription result before the Me/Them merge.
public struct ChannelSegment: Sendable, Equatable {
    /// Seconds from the start of the audio file.
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    /// Mean token probability, 0...1.
    public let confidence: Float

    public init(start: TimeInterval, end: TimeInterval, text: String, confidence: Float) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

/// Result of transcribing one lane.
public struct ChannelTranscription: Sendable, Equatable {
    public let segments: [ChannelSegment]
    /// Detected language code (e.g. "en").
    public let language: String
}

/// Errors thrown by ``WhisperTranscriber``.
public enum TranscriberError: Error {
    case modelLoadFailed(path: String)
    case audioLoadFailed(String)
    /// whisper_full returned a non-zero status.
    case transcriptionFailed(Int32)
    case cancelled
}

/// Cancellation flag readable from whisper's C abort callback.
private final class AbortBox: @unchecked Sendable {
    let flag = Atomic<Bool>(false)
}

/// Sendable wrapper for the `whisper_context *` so the dedicated queue's
/// closure may capture it. Safety: all whisper calls on one context are
/// serialized by that queue.
private struct ContextRef: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// In-process whisper.cpp bridge. Owns one `whisper_context` (the ~1.6 GB
/// model stays loaded for reuse across both lanes of a call); the heavy
/// `whisper_full` call runs on a dedicated serial queue so it never blocks
/// the cooperative pool. Cancellation propagates through whisper's abort
/// callback (checked between decoder passes).
public actor WhisperTranscriber {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "WhisperTranscriber")

    private let context: ContextRef
    private let vadModelPath: String?
    private let queue = DispatchQueue(label: "dev.collinsadi.saaa.whisper", qos: .userInitiated)

    /// Loads the model (GPU/Metal by default). `vadModelPath` enables
    /// whisper.cpp's integrated Silero VAD trimming — strongly recommended:
    /// it is faster and suppresses silence hallucinations.
    public init(modelPath: URL, vadModelPath: URL?) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let pointer = whisper_init_from_file_with_params(modelPath.path, params) else {
            throw TranscriberError.modelLoadFailed(path: modelPath.path)
        }
        self.context = ContextRef(pointer: pointer)
        self.vadModelPath = vadModelPath?.path
    }

    deinit {
        whisper_free(context.pointer)
    }

    /// Transcribes one 16 kHz mono WAV file (the capture pipeline's output
    /// format). `initialPrompt` biases decoding toward project vocabulary.
    public func transcribe(
        wavFile: URL,
        initialPrompt: String? = nil
    ) async throws -> ChannelTranscription {
        let samples = try WavLoader.loadMono16k(wavFile)
        return try await transcribe(samples: samples, initialPrompt: initialPrompt)
    }

    /// Transcribes raw 16 kHz mono float samples.
    public func transcribe(
        samples: [Float],
        initialPrompt: String? = nil
    ) async throws -> ChannelTranscription {
        guard !samples.isEmpty else {
            return ChannelTranscription(segments: [], language: "en")
        }
        let abort = AbortBox()
        let contextRef = context
        let vadModelPath = self.vadModelPath
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let result = Result {
                        try Self.run(
                            context: contextRef.pointer, samples: samples,
                            initialPrompt: initialPrompt,
                            vadModelPath: vadModelPath, abort: abort)
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            abort.flag.store(true, ordering: .relaxed)
        }
    }

    /// The blocking whisper_full run — executes on the dedicated queue.
    private static func run(
        context: OpaquePointer,
        samples: [Float],
        initialPrompt: String?,
        vadModelPath: String?,
        abort: AbortBox
    ) throws -> ChannelTranscription {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = false
        params.suppress_blank = true

        // C strings must outlive the whisper_full call.
        let promptC = initialPrompt.map { strdup($0) }
        let vadC = vadModelPath.map { strdup($0) }
        defer {
            promptC??.deallocate()
            vadC??.deallocate()
        }
        if let promptC {
            params.initial_prompt = UnsafePointer(promptC)
        }
        if let vadC {
            params.vad = true
            params.vad_model_path = UnsafePointer(vadC)
            params.vad_params = whisper_vad_default_params()
        }

        let abortPointer = Unmanaged.passRetained(abort).toOpaque()
        defer { Unmanaged<AbortBox>.fromOpaque(abortPointer).release() }
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<AbortBox>.fromOpaque(userData)
                .takeUnretainedValue().flag.load(ordering: .relaxed)
        }
        params.abort_callback_user_data = abortPointer

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        if abort.flag.load(ordering: .relaxed) {
            throw TranscriberError.cancelled
        }
        guard status == 0 else {
            throw TranscriberError.transcriptionFailed(status)
        }

        var segments: [ChannelSegment] = []
        let count = whisper_full_n_segments(context)
        segments.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let textC = whisper_full_get_segment_text(context, i) else { continue }
            let text = String(cString: textC).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // t0/t1 are in centiseconds.
            let start = TimeInterval(whisper_full_get_segment_t0(context, i)) / 100
            let end = TimeInterval(whisper_full_get_segment_t1(context, i)) / 100
            let tokenCount = whisper_full_n_tokens(context, i)
            var probabilitySum: Float = 0
            for j in 0..<tokenCount {
                probabilitySum += whisper_full_get_token_p(context, i, j)
            }
            let confidence = tokenCount > 0 ? probabilitySum / Float(tokenCount) : 0
            segments.append(ChannelSegment(
                start: start, end: end, text: text, confidence: confidence))
        }

        let langID = whisper_full_lang_id(context)
        let language = whisper_lang_str(langID).map { String(cString: $0) } ?? "en"
        return ChannelTranscription(segments: segments, language: language)
    }
}
