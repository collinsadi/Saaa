import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

@Suite struct WavWriterTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-test-\(UUID().uuidString).wav")
    }

    @Test func writesCanonicalHeaderAndPatchesSizes() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sampleRate: 16_000)
        try writer.append([0, 1000, -1000, 32767, -32768])
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 10)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")

        func u32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u16(_ offset: Int) -> UInt16 {
            data[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        #expect(u32(4) == 36 + 10)      // RIFF size
        #expect(u16(20) == 1)           // PCM
        #expect(u16(22) == 1)           // mono
        #expect(u32(24) == 16_000)      // sample rate
        #expect(u32(28) == 32_000)      // byte rate
        #expect(u16(32) == 2)           // block align
        #expect(u16(34) == 16)          // bits per sample
        #expect(u32(40) == 10)          // data size
    }

    @Test func roundTripsThroughAVAudioFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // 0.5 s of a 440 Hz sine at 16 kHz.
        let sampleRate = 16_000
        let count = sampleRate / 2
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let phase = 2.0 * Double.pi * 440.0 * Double(i) / Double(sampleRate)
            samples[i] = Int16(sin(phase) * 20_000)
        }

        let writer = try WavWriter(url: url, sampleRate: sampleRate)
        try writer.append(samples)
        #expect(abs(writer.duration - 0.5) < 0.001)
        try writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(count))
    }

    @Test func appendAfterFinishThrows() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url)
        try writer.finish()
        #expect(throws: WavWriterError.alreadyFinished) {
            try writer.append([1, 2, 3])
        }
    }
}
