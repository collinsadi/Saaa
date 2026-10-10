import Foundation
import Synchronization
import Testing
@testable import AudioCapture

@Suite struct LiveSinkTests {

    /// Every sample written to the WAV also reaches the live sink, in order,
    /// with contiguous start frames (the live transcriber's timeline).
    @Test func liveSinkMirrorsTheWavExactly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-sink-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let ring = RingBuffer(minimumCapacity: 1 << 19)
        let pipeline = try LanePipeline(
            ring: ring, gap: SilenceGapBox(), fileURL: url,
            format: LaneFormat(channels: 1, sampleRate: 48_000))
        let received = Mutex<[(start: Int64, count: Int)]>([])
        pipeline.liveSink = { samples, start in
            received.withLock { $0.append((start, samples.count)) }
        }

        var chunk = [Float32](repeating: 0, count: 4_800)
        for cycle in 0..<10 {
            for i in chunk.indices {
                chunk[i] = sinf(Float(cycle * 4_800 + i) * 0.05) * 0.3
            }
            chunk.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
            _ = try pipeline.drainCycle()
        }
        // A rebuild gap mid-stream must also reach the sink.
        pipeline.gap.add(frames: 1_600)
        _ = try pipeline.drainCycle()
        try pipeline.finish()

        let chunks = received.withLock { $0 }
        #expect(!chunks.isEmpty)
        var expected: Int64 = 0
        for chunk in chunks {
            #expect(chunk.start == expected)
            expected += Int64(chunk.count)
        }
        let file = try AVAudioFileProbe.length(of: url)
        #expect(expected == file)
        // 1 s of 48 kHz audio → ~16_000 frames, plus the 1_600-frame gap.
        #expect(abs(Int(expected) - 17_600) < 32)
    }

    @Test func chunkCarriesItsLane() {
        let chunk = LiveAudioChunk(lane: .system, samples: [1, 2, 3], startFrame: 160)
        #expect(chunk.lane == .system)
        #expect(chunk.startFrame == 160)
        #expect(LiveAudioChunk.sampleRate == 16_000)
    }
}

import AVFoundation

enum AVAudioFileProbe {
    static func length(of url: URL) throws -> Int64 {
        try AVAudioFile(forReading: url).length
    }
}
