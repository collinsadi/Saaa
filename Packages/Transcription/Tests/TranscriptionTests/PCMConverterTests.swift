import AVFoundation
import Testing
@testable import Transcription

@Suite struct PCMConverterTests {

    @Test func passthroughKeepsSamples() throws {
        let converter = PCMConverter(target: PCMConverter.sourceFormat)
        #expect(converter.isPassthrough)
        let buffer = try #require(converter.convert([1, 2, 3, -4]))
        #expect(buffer.frameLength == 4)
        #expect(buffer.int16ChannelData?[0][3] == -4)
    }

    @Test func resamplesToFloat48k() throws {
        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = PCMConverter(target: target)
        #expect(!converter.isPassthrough)
        var produced: AVAudioFrameCount = 0
        let tone = (0..<1_600).map { Int16(sin(Double($0) * 0.2) * 8_000) }
        for _ in 0..<10 {
            if let buffer = converter.convert(tone) { produced += buffer.frameLength }
        }
        // 1 s of input at 16 kHz ≈ 48_000 frames out (minus resampler latency).
        #expect(produced > 44_000 && produced <= 48_256)
    }

    @Test func emptyInputYieldsNothing() {
        #expect(PCMConverter(target: nil).convert([]) == nil)
    }
}
