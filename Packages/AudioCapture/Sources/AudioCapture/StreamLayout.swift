import CoreAudio
import Foundation

/// Frozen attribution of the aggregate device's input buffers to the mic and
/// tap lanes, computed once at setup and captured immutably by the IO block.
///
/// Layout rule (contract §3): `mBuffers[i]` corresponds 1:1, in order, to the
/// aggregate's input streams; sub-device (mic) streams come first, tap streams
/// after. Tap placement after sub-devices is empirical, so attribution is
/// verified from per-stream formats — never assumed.
///
/// Each lane reads exactly ONE buffer (its first stream). Copying additional
/// non-interleaved sibling buffers into a single ring would block-interleave
/// frames and corrupt the converter's input, so extra streams are ignored;
/// channel 0 content is what speech transcription needs.
struct StreamLayout: Sendable, Equatable {
    /// Index into `mBuffers` for the mic lane.
    let micBufferIndex: Int
    /// Index into `mBuffers` for the tap lane.
    let tapBufferIndex: Int
    /// Interleaved channel count of the mic buffer.
    let micChannels: Int
    /// Interleaved channel count of the tap buffer.
    let tapChannels: Int
    /// Sample rate of the mic stream (the aggregate's clock master).
    let micSampleRate: Double
    /// Sample rate of the tap stream.
    let tapSampleRate: Double

    /// Describes one input stream for attribution.
    struct StreamInfo: Equatable {
        let channels: Int
        let sampleRate: Double
        let isFloat: Bool
    }

    /// Attributes ordered input streams to lanes given the tap's own format.
    ///
    /// The tap lane is the *trailing* run of streams matching the tap format's
    /// channel count; everything before it is the mic. Throws
    /// ``CaptureError/layoutAmbiguous`` when attribution cannot be made safely.
    static func resolve(
        inputStreams: [StreamInfo],
        tapChannels: Int
    ) throws -> (micIndex: Int, tapIndex: Int) {
        guard inputStreams.count >= 2 else { throw CaptureError.layoutAmbiguous }

        // Find the start of the trailing run whose channel count matches the tap.
        var tapStart = inputStreams.count
        while tapStart > 0, inputStreams[tapStart - 1].channels == tapChannels {
            tapStart -= 1
        }
        // The tap contributes at least the last stream; the mic needs at least
        // one stream before the run. If the run swallows everything (e.g. a
        // 2-channel mic before a 2-channel tap), fall back to positional
        // attribution only when there are exactly two streams: mic first (sub-
        // devices precede taps), tap last.
        if tapStart == 0 {
            guard inputStreams.count == 2 else { throw CaptureError.layoutAmbiguous }
            return (micIndex: 0, tapIndex: 1)
        }
        guard tapStart < inputStreams.count else { throw CaptureError.layoutAmbiguous }
        return (micIndex: 0, tapIndex: tapStart)
    }

    /// Reads the aggregate's input streams and freezes the lane attribution.
    static func catalog(
        aggregateID: AudioObjectID,
        tapFormat: AudioStreamBasicDescription
    ) throws -> StreamLayout {
        let streamIDs: [AudioObjectID]
        do {
            streamIDs = try HAL.inputStreams(aggregateID)
        } catch {
            throw CaptureError.layoutAmbiguous
        }
        let infos: [StreamInfo] = try streamIDs.map { id in
            guard let asbd = HAL.streamVirtualFormat(id) else {
                throw CaptureError.layoutAmbiguous
            }
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw CaptureError.unsupportedTapFormat
            }
            return StreamInfo(
                channels: Int(asbd.mChannelsPerFrame),
                sampleRate: asbd.mSampleRate,
                isFloat: true)
        }
        let (micIndex, tapIndex) = try resolve(
            inputStreams: infos, tapChannels: Int(tapFormat.mChannelsPerFrame))
        return StreamLayout(
            micBufferIndex: micIndex,
            tapBufferIndex: tapIndex,
            micChannels: infos[micIndex].channels,
            tapChannels: infos[tapIndex].channels,
            micSampleRate: infos[micIndex].sampleRate,
            tapSampleRate: infos[tapIndex].sampleRate)
    }
}
