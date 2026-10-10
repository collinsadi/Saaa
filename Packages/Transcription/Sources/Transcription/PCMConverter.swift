import AVFoundation
import Foundation

/// Wraps 16 kHz mono Int16 capture samples into buffers in the analyzer's
/// preferred format. SpeechAnalyzer never converts audio itself, so this is
/// mandatory whenever the formats differ. Stateful (resampler history), so
/// one converter serves one lane, fed in order.
final class PCMConverter {

    static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    let target: AVAudioFormat
    private let converter: AVAudioConverter?

    init(target: AVAudioFormat?) {
        let target = target ?? Self.sourceFormat
        self.target = target
        if Self.matches(target, Self.sourceFormat) {
            converter = nil
        } else {
            converter = AVAudioConverter(from: Self.sourceFormat, to: target)
        }
    }

    /// True when no conversion is needed.
    var isPassthrough: Bool { converter == nil }

    func convert(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let source = Self.makeSourceBuffer(samples) else { return nil }
        guard let converter else { return source }
        let ratio = target.sampleRate / Self.sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    static func makeSourceBuffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.int16ChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    static func matches(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && (lhs.channelCount == 1 || lhs.isInterleaved == rhs.isInterleaved)
    }
}
