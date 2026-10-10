import AVFoundation
import Foundation

/// End-to-end check of the live pipeline without a microphone: synthesize
/// speech, stream it through ``LiveTranscriber`` in 100 ms chunks, and
/// compare. Used by the package tests and the app's `--selftest-transcribe`.
public enum SpeechSelfTest {

    public struct Report: Sendable, CustomStringConvertible {
        public var engine: String
        public var locale: String
        public var expected: String
        public var transcribed: String
        public var partialCount: Int
        public var finalCount: Int
        public var audioSeconds: Double
        public var wallSeconds: Double
        /// Wall time from the first fed chunk to the first partial.
        public var firstPartialSeconds: Double?
        /// Share of expected words that were heard, 0...1.
        public var wordRecall: Double

        public var description: String {
            """
            engine=\(engine) locale=\(locale) audio=\(String(format: "%.1f", audioSeconds))s wall=\(String(format: "%.1f", wallSeconds))s \
            firstPartial=\(firstPartialSeconds.map { String(format: "%.2f", $0) } ?? "none")s partials=\(partialCount) finals=\(finalCount) recall=\(String(format: "%.2f", wordRecall))
            expected:    \(expected)
            transcribed: \(transcribed)
            """
        }
    }

    public static let sampleText =
        "Our quarterly revenue grew by twelve percent, and we plan to hire three engineers before the launch in March."

    /// Runs the check. `realtime` paces input at speaking speed (latency
    /// measurement); otherwise audio is fed as fast as it converts.
    public static func run(
        text: String = sampleText,
        locale: Locale = Locale(identifier: "en-US"),
        realtime: Bool = true
    ) async throws -> Report {
        let samples = try await synthesize(text, language: locale.identifier(.bcp47))
        let padded = samples + [Int16](repeating: 0, count: 16_000)
        let transcriber = LiveTranscriber()
        let resolution = try await transcriber.start(locale: locale)

        let clock = ContinuousClock()
        let started = clock.now
        let consumer = Task { () -> (LiveTranscript, Int, Duration?) in
            var transcript = LiveTranscript()
            var partials = 0
            var firstPartial: Duration?
            for await event in transcriber.events {
                if case .partial = event {
                    partials += 1
                    if firstPartial == nil { firstPartial = started.duration(to: clock.now) }
                }
                transcript.apply(event)
            }
            return (transcript, partials, firstPartial)
        }

        let chunk = 1_600
        var frame = 0
        while frame < padded.count {
            let end = min(frame + chunk, padded.count)
            transcriber.append(.them, samples: Array(padded[frame..<end]), startFrame: Int64(frame))
            frame = end
            try await Task.sleep(for: realtime ? .milliseconds(100) : .milliseconds(2))
        }
        await transcriber.finish()
        let (transcript, partials, firstPartial) = await consumer.value
        let heard = transcript.entries.map(\.segment.text).joined(separator: " ")
        let expectedWords = TextSimilarity.words(text)
        let heardWords = Set(TextSimilarity.words(heard))
        let recall = expectedWords.isEmpty ? 0
            : Double(expectedWords.filter { heardWords.contains($0) }.count) / Double(expectedWords.count)
        return Report(
            engine: resolution.engine.rawValue,
            locale: resolution.locale.identifier,
            expected: text,
            transcribed: heard,
            partialCount: partials,
            finalCount: transcript.entries.count,
            audioSeconds: Double(padded.count) / 16_000,
            wallSeconds: Self.seconds(started.duration(to: clock.now)),
            firstPartialSeconds: firstPartial.map(Self.seconds),
            wordRecall: recall)
    }

    /// Speech synthesis → 16 kHz mono Int16.
    public static func synthesize(_ text: String, language: String = "en-US") async throws -> [Int16] {
        let collector = SynthesisCollector()
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
        let samples: [Int16] = try await withCheckedThrowingContinuation { continuation in
            collector.arm(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    collector.finish()
                } else {
                    collector.append(pcm)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                collector.fail(TranscriptionError.engineUnavailable("speech synthesis timed out"))
            }
        }
        // The synthesizer must outlive its callbacks.
        withExtendedLifetime(synthesizer) {}
        guard !samples.isEmpty else { throw TranscriptionError.engineUnavailable("speech synthesis produced no audio") }
        return samples
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Converts synthesizer buffers to 16 kHz mono Int16 and resumes the
/// waiting continuation exactly once.
final class SynthesisCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Int16], Error>?
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []
    private var done = false

    func arm(_ continuation: CheckedContinuation<[Int16], Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !done else { return }
            let target = PCMConverter.sourceFormat
            if converter == nil {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 256)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let channel = output.int16ChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        }
    }

    func finish() {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<[Int16], Error>?, [Int16]) in
            guard !done else { return (nil, []) }
            done = true
            let pending = self.continuation
            self.continuation = nil
            return (pending, samples)
        }
        continuation?.resume(returning: result)
    }

    func fail(_ error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<[Int16], Error>? in
            guard !done else { return nil }
            done = true
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume(throwing: error)
    }
}
