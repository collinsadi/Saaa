import Core
import Foundation

/// Interleaves the two lanes' timestamped segments into one Me/Them
/// transcript. Pure logic — unit-tested without audio.
public enum TranscriptMerger {

    /// Merges by start time. Both lanes share t=0 (the capture pipeline
    /// guarantees sample-aligned files), so plain timestamp ordering is
    /// correct. Ties: the remote side first (they were being replied to).
    /// Empty/whitespace segments are dropped; language prefers the mic lane
    /// (the user's speech) unless it produced nothing.
    public static func merge(
        mic: ChannelTranscription,
        system: ChannelTranscription
    ) -> Transcript {
        var merged: [TranscriptSegment] = []
        merged.reserveCapacity(mic.segments.count + system.segments.count)
        for segment in mic.segments where !segment.text.isEmpty {
            merged.append(TranscriptSegment(
                speaker: .me, start: segment.start, end: segment.end,
                text: segment.text, confidence: segment.confidence))
        }
        for segment in system.segments where !segment.text.isEmpty {
            merged.append(TranscriptSegment(
                speaker: .them(label: nil), start: segment.start, end: segment.end,
                text: segment.text, confidence: segment.confidence))
        }
        merged.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.speaker != rhs.speaker { return lhs.speaker == .them(label: nil) }
            return lhs.end < rhs.end
        }
        let language = mic.segments.isEmpty ? system.language : mic.language
        return Transcript(segments: merged, language: language)
    }
}
