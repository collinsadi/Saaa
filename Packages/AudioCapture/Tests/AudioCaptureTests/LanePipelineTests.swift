import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

@Suite struct LanePipelineTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-test-\(UUID().uuidString).wav")
    }

    /// 48 kHz stereo float sine through the pipeline → 16 kHz mono WAV of the
    /// right length with the tone intact.
    @Test func resamplesAndDownmixesStereo48kToMono16k() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let ring = RingBuffer(minimumCapacity: 1 << 19)
        let pipeline = try LanePipeline(
            ring: ring, gap: SilenceGapBox(), fileURL: url,
            format: LaneFormat(channels: 2, sampleRate: 48_000))

        // 2 s of 440 Hz, interleaved stereo, in 4800-frame chunks.
        let totalFrames = 96_000
        let chunkFrames = 4_800
        var chunk = [Float32](repeating: 0, count: chunkFrames * 2)
        var frame = 0
        while frame < totalFrames {
            for i in 0..<chunkFrames {
                let sample = sinf(2 * .pi * 440 * Float(frame + i) / 48_000) * 0.5
                chunk[i * 2] = sample
                chunk[i * 2 + 1] = sample
            }
            chunk.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
            _ = try pipeline.drainCycle()
            frame += chunkFrames
        }
        try pipeline.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        // SRC preserves total duration to within a few frames.
        #expect(abs(Int(file.length) - 32_000) < 16)

        // The 440 Hz tone survives: read back and check RMS ≈ 0.35 (0.5/√2).
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let floats = buffer.floatChannelData![0]
        let levels = AudioLevels(samples: floats, count: Int(buffer.frameLength))
        #expect(abs(levels.rms - 0.3535) < 0.01)
    }

    /// Pending gap silence lands in the file ahead of later samples.
    @Test func insertsGapSilenceBeforeSubsequentAudio() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let ring = RingBuffer(minimumCapacity: 1 << 16)
        let gap = SilenceGapBox()
        let pipeline = try LanePipeline(
            ring: ring, gap: gap, fileURL: url,
            format: LaneFormat(channels: 1, sampleRate: 16_000))

        gap.add(frames: 8_000) // 0.5 s of silence
        let tone = [Float32](repeating: 0.5, count: 1_600)
        tone.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
        _ = try pipeline.drainCycle()
        try pipeline.finish()

        let file = try AVAudioFile(forReading: url)
        // 8000 silence + ~1600 tone frames (1:1 rate, converter still runs).
        #expect(abs(Int(file.length) - 9_600) < 16)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let floats = buffer.floatChannelData![0]
        // First 0.4 s must be pure silence; the tone follows.
        let silencePrefix = AudioLevels(samples: floats, count: 6_400)
        #expect(silencePrefix.peak == 0)
        let tail = AudioLevels(
            samples: floats + 8_000, count: Int(buffer.frameLength) - 8_000)
        #expect(tail.peak > 0.4)
    }

    /// Reconfigure mid-stream (device change): output stays continuous.
    @Test func reconfigureKeepsWriterAndAppends() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let ring = RingBuffer(minimumCapacity: 1 << 16)
        let pipeline = try LanePipeline(
            ring: ring, gap: SilenceGapBox(), fileURL: url,
            format: LaneFormat(channels: 1, sampleRate: 16_000))

        let first = [Float32](repeating: 0.25, count: 3_200)
        first.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
        _ = try pipeline.drainCycle()

        try pipeline.reconfigure(to: LaneFormat(channels: 2, sampleRate: 48_000))
        var second = [Float32](repeating: 0, count: 9_600 * 2)
        for i in 0..<9_600 {
            second[i * 2] = 0.25
            second[i * 2 + 1] = 0.25
        }
        second.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
        _ = try pipeline.drainCycle()
        try pipeline.finish()

        let file = try AVAudioFile(forReading: url)
        // 3200 frames (1:1) + 9600@48k → 3200@16k ≈ 6400 total.
        #expect(abs(Int(file.length) - 6_400) < 32)
    }
}
