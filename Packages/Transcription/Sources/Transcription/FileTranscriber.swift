import AVFoundation
import Foundation

/// Transcribes recorded audio (imports, or a lane re-run) with the accurate,
/// non-progressive model. Input: the 16 kHz mono WAVs the capture and
/// import pipelines produce.
public enum FileTranscriber {

    public struct Segment: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
    }

    public static func transcribe(
        wav url: URL,
        lane: LiveTranscript.Lane,
        locale: Locale,
        vocabulary: [String] = [],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Segment] {
        guard let resolution = await SpeechAssets.resolve(locale) else {
            throw TranscriptionError.unsupportedLanguage(locale.identifier)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw TranscriptionError.audioUnreadable(error.localizedDescription)
        }
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
            throw TranscriptionError.audioUnreadable("expected 16 kHz mono")
        }

        let collector = SegmentCollector()
        let speechLane = SpeechLane(lane: lane)
        try await speechLane.start(resolution, live: false, vocabulary: vocabulary) { result in
            if result.isFinal, result.error == nil {
                collector.add(Segment(start: result.start, end: result.end, text: result.text))
            }
        }
        let total = max(1, file.length)
        let chunkFrames: AVAudioFrameCount = 16_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            await speechLane.cancel()
            throw TranscriptionError.audioUnreadable("cannot allocate buffer")
        }
        var frame: Int64 = 0
        while frame < file.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                await speechLane.cancel()
                throw TranscriptionError.audioUnreadable(error.localizedDescription)
            }
            let count = Int(buffer.frameLength)
            guard count > 0, let channel = buffer.int16ChannelData?[0] else { break }
            speechLane.append(Array(UnsafeBufferPointer(start: channel, count: count)), startFrame: frame)
            frame += Int64(count)
            progress?(Double(frame) / Double(total) * 0.9)
        }
        await speechLane.finish()
        progress?(1)
        return collector.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Thread-safe accumulator for results arriving off the caller's task.
final class SegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileTranscriber.Segment] = []

    func add(_ segment: FileTranscriber.Segment) {
        lock.withLock { storage.append(segment) }
    }

    var segments: [FileTranscriber.Segment] {
        lock.withLock { storage.sorted { $0.start < $1.start } }
    }
}
