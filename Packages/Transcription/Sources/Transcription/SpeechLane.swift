import AVFoundation
import CoreMedia
import Foundation
import Speech
import os

/// One speaker's live SpeechAnalyzer session: converts capture chunks to the
/// analyzer's format, feeds them in order, and reports volatile and final
/// phrases. Thread-safe: `append` may be called from any one task.
final class SpeechLane: @unchecked Sendable {

    struct Result: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var isFinal: Bool
        var error: String?

        init(start: TimeInterval, end: TimeInterval, text: String, isFinal: Bool) {
            self.start = start.isFinite ? start : 0
            self.end = end.isFinite ? end : start
            self.text = text
            self.isFinal = isFinal
            self.error = nil
        }

        static func failure(_ message: String) -> Result {
            var result = Result(start: 0, end: 0, text: "", isFinal: true)
            result.error = message
            return result
        }
    }

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "SpeechLane")

    let lane: LiveTranscript.Lane

    private let lock = NSLock()
    private var converter: PCMConverter?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var nextFrame: Int64 = 0
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    init(lane: LiveTranscript.Lane) {
        self.lane = lane
    }

    /// Builds and starts the analyzer. Retries once ignoring the system's
    /// concurrent-analysis limit (two lanes run at once).
    func start(
        _ resolution: SpeechAssets.Resolution,
        live: Bool,
        vocabulary: [String],
        onResult: @escaping @Sendable (Result) -> Void
    ) async throws {
        do {
            try await begin(resolution, live: live, vocabulary: vocabulary, ignoringLimits: false, onResult: onResult)
        } catch {
            Self.log.warning("lane \(self.lane.rawValue, privacy: .public) start failed (\(String(describing: error), privacy: .public)); retrying without resource limits")
            await teardown()
            try await begin(resolution, live: live, vocabulary: vocabulary, ignoringLimits: true, onResult: onResult)
        }
    }

    private func begin(
        _ resolution: SpeechAssets.Resolution,
        live: Bool,
        vocabulary: [String],
        ignoringLimits: Bool,
        onResult: @escaping @Sendable (Result) -> Void
    ) async throws {
        let module = TranscriberModule.make(resolution, live: live)
        let modules = [module.speechModule]
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        let options: SpeechAnalyzer.Options
        if #available(macOS 27, *), ignoringLimits {
            options = SpeechAnalyzer.Options(
                priority: .userInitiated, modelRetention: .processLifetime, ignoresResourceLimits: true)
        } else {
            options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        }
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(terms.prefix(100))
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let results = module.consumeResults(onResult)
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            results.cancel()
            continuation.finish()
            throw error
        }
        lock.withLock {
            self.converter = PCMConverter(target: format)
            self.input = continuation
            self.analyzer = analyzer
            self.resultsTask = results
            self.nextFrame = 0
        }
        Self.log.info("lane \(self.lane.rawValue, privacy: .public) live (\(resolution.engine.rawValue, privacy: .public), \(resolution.locale.identifier, privacy: .public))")
    }

    /// Feeds 16 kHz mono samples that start at `startFrame` on the lane's timeline.
    func append(_ samples: [Int16], startFrame: Int64) {
        lock.withLock {
            guard let input, let converter, let buffer = converter.convert(samples) else { return }
            if startFrame != nextFrame {
                input.yield(AnalyzerInput(
                    buffer: buffer,
                    bufferStartTime: CMTime(value: startFrame, timescale: 16_000)))
            } else {
                input.yield(AnalyzerInput(buffer: buffer))
            }
            nextFrame = startFrame + Int64(samples.count)
        }
    }

    /// Ends input, finalizes everything heard, and waits for the last results.
    func finish() async {
        let (input, analyzer, results) = lock.withLock {
            (self.input, self.analyzer, self.resultsTask)
        }
        input?.finish()
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Self.log.error("lane \(self.lane.rawValue, privacy: .public) finalize failed: \(String(describing: error), privacy: .public)")
                await analyzer.cancelAndFinishNow()
            }
        }
        await results?.value
        lock.withLock {
            self.input = nil
            self.analyzer = nil
            self.resultsTask = nil
        }
    }

    /// Stops immediately, dropping unfinalized audio.
    func cancel() async {
        await teardown()
    }

    private func teardown() async {
        let (input, analyzer, results) = lock.withLock {
            let snapshot = (self.input, self.analyzer, self.resultsTask)
            self.input = nil
            self.analyzer = nil
            self.resultsTask = nil
            return snapshot
        }
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
    }
}
