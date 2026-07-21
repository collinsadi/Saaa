import AVFoundation
import Foundation
import Synchronization

/// Shared t=0 anchor: the first IO callback's host time. Written once by the
/// RT thread, read by the control plane.
final class HostTimeAnchor: @unchecked Sendable {
    let raw = Atomic<UInt64>(0)
}

/// Cross-thread mailbox for silence frames the drain must insert into a lane
/// after a rebuild gap, keeping the two WAV timelines aligned.
final class SilenceGapBox: @unchecked Sendable {
    private let pendingFrames = Atomic<Int>(0)

    func add(frames: Int) {
        pendingFrames.wrappingAdd(frames, ordering: .relaxed)
    }

    /// Returns and clears the pending frame count.
    func take() -> Int {
        pendingFrames.exchange(0, ordering: .relaxed)
    }
}

/// Source format of one lane's ring content.
struct LaneFormat: Sendable, Equatable {
    /// Interleaved channels per frame in the ring.
    let channels: Int
    /// Source sample rate in Hz.
    let sampleRate: Double
}

/// Publishes a lane's source format to the drain task. The tap path fills it
/// at setup; the SCK path fills it from the first delivered sample buffer.
final class LaneFormatBox: @unchecked Sendable {
    private let state = Mutex<LaneFormat?>(nil)

    func publish(_ format: LaneFormat) {
        state.withLock { $0 = format }
    }

    var current: LaneFormat? {
        state.withLock { $0 }
    }
}

/// Cross-thread stop request for the drain loop.
final class StopFlag: @unchecked Sendable {
    private let flag = Atomic<Bool>(false)

    func raise() { flag.store(true, ordering: .releasing) }
    var isRaised: Bool { flag.load(ordering: .acquiring) }
}

/// Cross-thread boolean (e.g. "target is currently emitting audio").
final class BoolBox: @unchecked Sendable {
    private let value = Atomic<Bool>(false)

    func set(_ newValue: Bool) { value.store(newValue, ordering: .relaxed) }
    var get: Bool { value.load(ordering: .relaxed) }
}

/// One lane's non-real-time pipeline: ring → levels → resample/downmix →
/// 16 kHz mono Int16 WAV. Owned exclusively by the drain task.
final class LanePipeline {

    /// Output format shared by both lanes: 16 kHz / mono / Int16 interleaved.
    static let outputSampleRate = 16_000.0

    let ring: RingBuffer
    let gap: SilenceGapBox
    private let writer: WavWriter
    private var converter: AVAudioConverter
    private var sourceFormat: AVAudioFormat
    private var sourceBuffer: AVAudioPCMBuffer
    private var outputBuffer: AVAudioPCMBuffer
    private var scratch: [Float32]
    private var lastDropped = 0
    /// True until the lane sees its first non-zero sample (permission heuristic).
    private(set) var allZeroSoFar = true
    /// Diagnostics: read-loop chunks seen / chunks containing signal.
    private(set) var chunkCount = 0
    private(set) var nonzeroChunkCount = 0
    /// The format the pipeline is currently configured for.
    private(set) var format: LaneFormat

    /// Frames per drain read — sized for ~0.5 s of source audio headroom.
    private var readCapacityFrames: Int

    /// Builds converter, scratch, and reusable buffers for `format`.
    private static func makeStages(
        _ format: LaneFormat
    ) throws -> (AVAudioFormat, AVAudioConverter, AVAudioPCMBuffer, AVAudioPCMBuffer, Int) {
        guard let src = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels), interleaved: true)
        else { throw CaptureError.unsupportedTapFormat }
        guard let dst = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Self.outputSampleRate,
            channels: 1, interleaved: true)
        else { throw CaptureError.unsupportedTapFormat }
        guard let converter = AVAudioConverter(from: src, to: dst) else {
            throw CaptureError.unsupportedTapFormat
        }
        let readCapacityFrames = Int(format.sampleRate / 2)
        let dstCapacity = AVAudioFrameCount(
            Double(readCapacityFrames) * Self.outputSampleRate / format.sampleRate + 64)
        guard let srcBuf = AVAudioPCMBuffer(
                pcmFormat: src, frameCapacity: AVAudioFrameCount(readCapacityFrames)),
              let dstBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: dstCapacity)
        else { throw CaptureError.unsupportedTapFormat }
        return (src, converter, srcBuf, dstBuf, readCapacityFrames)
    }

    init(ring: RingBuffer, gap: SilenceGapBox, fileURL: URL, format: LaneFormat) throws {
        self.ring = ring
        self.gap = gap
        self.format = format
        (sourceFormat, converter, sourceBuffer, outputBuffer, readCapacityFrames) =
            try Self.makeStages(format)
        scratch = [Float32](repeating: 0, count: readCapacityFrames * format.channels)
        do {
            self.writer = try WavWriter(url: fileURL, sampleRate: Int(Self.outputSampleRate))
        } catch {
            throw CaptureError.fileError(underlying: error)
        }
    }

    /// Rebuilds the conversion stages for a new source format (device/format
    /// change rebuild), flushing the old converter's SRC tail first. The
    /// writer, ring, and gap box survive so the output timeline is continuous.
    func reconfigure(to newFormat: LaneFormat) throws {
        guard newFormat != format else { return }
        try runConverter(endOfStream: true)
        format = newFormat
        (sourceFormat, converter, sourceBuffer, outputBuffer, readCapacityFrames) =
            try Self.makeStages(newFormat)
        scratch = [Float32](repeating: 0, count: readCapacityFrames * newFormat.channels)
    }

    var fileURL: URL { writer.url }
    var duration: TimeInterval { writer.duration }

    /// One drain cycle. Returns the lane's levels (pre-conversion floats) and
    /// the ring-overrun delta since the previous cycle.
    func drainCycle() throws -> (levels: AudioLevels, droppedDelta: Int) {
        // Insert any pending rebuild-gap silence first so ordering is correct.
        let gapFrames = gap.take()
        if gapFrames > 0 {
            try appendSilence(frames: gapFrames)
        }

        var levels = AudioLevels.zero
        let channels = Int(sourceFormat.channelCount)
        while true {
            let samples = scratch.withUnsafeMutableBufferPointer {
                ring.read(into: $0.baseAddress!, count: $0.count)
            }
            guard samples > 0 else { break }
            let cycleLevels = scratch.withUnsafeBufferPointer {
                AudioLevels(samples: $0.baseAddress!, count: samples)
            }
            if cycleLevels.peak > levels.peak {
                levels = cycleLevels
            }
            chunkCount += 1
            if cycleLevels.peak > 0 {
                nonzeroChunkCount += 1
                allZeroSoFar = false
            }
            let frames = samples / channels
            try convertAndAppend(frames: frames)
            if samples < scratch.count { break }
        }

        let droppedNow = ring.droppedSamples
        let droppedDelta = droppedNow - lastDropped
        lastDropped = droppedNow
        return (levels, droppedDelta)
    }

    /// Converts `frames` of `scratch` and appends to the WAV.
    private func convertAndAppend(frames: Int) throws {
        guard frames > 0 else { return }
        scratch.withUnsafeBufferPointer { src in
            sourceBuffer.floatChannelData![0].update(
                from: src.baseAddress!, count: frames * Int(sourceFormat.channelCount))
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frames)
        try runConverter(endOfStream: false)
    }

    /// Appends exactly `frames` of silence at output rate, bypassing the
    /// converter (silence needs no resampling; converter state is unaffected
    /// because rebuilds recreate the source anyway).
    private func appendSilence(frames: Int) throws {
        let zeros = [Int16](repeating: 0, count: min(frames, 16_000 * 60))
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, zeros.count)
            do {
                try zeros.withUnsafeBufferPointer { try writer.append($0.baseAddress!, count: n) }
            } catch {
                throw CaptureError.fileError(underlying: error)
            }
            remaining -= n
        }
    }

    /// Pushes `sourceBuffer` (or end-of-stream) through the converter and
    /// appends whatever it produces.
    private func runConverter(endOfStream: Bool) throws {
        var fed = false
        while true {
            outputBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { [sourceBuffer] _, outStatus in
                if endOfStream {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let error {
                throw CaptureError.fileError(underlying: error)
            }
            let produced = Int(outputBuffer.frameLength)
            if produced > 0 {
                do {
                    try writer.append(outputBuffer.int16ChannelData![0], count: produced)
                } catch {
                    throw CaptureError.fileError(underlying: error)
                }
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw CaptureError.fileError(
                    underlying: error ?? NSError(domain: "AudioCapture", code: -1))
            @unknown default:
                return
            }
        }
    }

    /// Header re-patch so a crash leaves a readable file.
    func checkpoint() throws {
        do {
            try writer.checkpoint()
        } catch {
            throw CaptureError.fileError(underlying: error)
        }
    }

    /// Drains the ring dry, flushes the converter's SRC tail (mandatory), and
    /// finalizes the WAV.
    func finish() throws {
        _ = try? drainCycle()
        try runConverter(endOfStream: true)
        do {
            try writer.finish()
        } catch {
            throw CaptureError.fileError(underlying: error)
        }
    }

    var totalDropped: Int { ring.droppedSamples }
}
