import AVFoundation
import Foundation

/// Loads the capture pipeline's 16 kHz mono WAVs into float samples for
/// whisper. Strict about format — anything else is a pipeline bug upstream.
enum WavLoader {

    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriberError.audioLoadFailed(String(describing: error))
        }
        guard file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1 else {
            throw TranscriberError.audioLoadFailed(
                "expected 16 kHz mono, got \(file.fileFormat.sampleRate) Hz "
                + "\(file.fileFormat.channelCount)ch at \(url.lastPathComponent)")
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw TranscriberError.audioLoadFailed("cannot allocate \(frames)-frame buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw TranscriberError.audioLoadFailed(String(describing: error))
        }
        guard let channelData = buffer.floatChannelData else {
            throw TranscriberError.audioLoadFailed("no float channel data")
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
