import AVFoundation
import Foundation
import Testing
@testable import Transcription

@Suite struct WavLoaderTests {

    private func writeWav(
        sampleRate: Double, channels: AVAudioChannelCount, frames: Int
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-test-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for i in 0..<frames {
                buffer.floatChannelData![channel][i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func loadsMono16k() throws {
        let url = try writeWav(sampleRate: 16_000, channels: 1, frames: 1_600)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try WavLoader.loadMono16k(url)
        #expect(samples.count == 1_600)
        #expect(abs(samples.max()! - 0.5) < 0.01)
    }

    @Test func rejectsWrongSampleRate() throws {
        let url = try writeWav(sampleRate: 44_100, channels: 1, frames: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: TranscriberError.self) {
            try WavLoader.loadMono16k(url)
        }
    }

    @Test func rejectsStereo() throws {
        let url = try writeWav(sampleRate: 16_000, channels: 2, frames: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: TranscriberError.self) {
            try WavLoader.loadMono16k(url)
        }
    }

    @Test func missingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")
        #expect(throws: TranscriberError.self) {
            try WavLoader.loadMono16k(url)
        }
    }
}
