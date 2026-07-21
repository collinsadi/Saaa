import Foundation

/// Who said a transcript segment.
public enum Speaker: Sendable, Equatable, Hashable, Codable {
    /// The user — captured from the microphone lane.
    case me
    /// The remote side — captured from the system lane. `label` is a later
    /// multi-speaker refinement; `nil` means "the other party".
    case them(label: String?)
}

/// One attributed, timestamped utterance.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public let speaker: Speaker
    /// Seconds from recording start.
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    /// Mean token probability, 0...1.
    public let confidence: Float

    public init(
        speaker: Speaker,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Float
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

/// A full call transcript, merged across both lanes.
public struct Transcript: Sendable, Equatable, Codable {
    public var segments: [TranscriptSegment]
    /// BCP-47-ish language code as detected by the transcriber (e.g. "en").
    public var language: String

    public init(segments: [TranscriptSegment], language: String) {
        self.segments = segments
        self.language = language
    }

    /// The canonical plain-text rendering: one `Me:`/`Them:` line per segment,
    /// in timeline order — the form handed to Claude Code.
    public var attributedText: String {
        segments.map { segment in
            let who: String
            switch segment.speaker {
            case .me: who = "Me"
            case .them(let label): who = label ?? "Them"
            }
            return "\(who): \(segment.text.trimmingCharacters(in: .whitespaces))"
        }
        .joined(separator: "\n")
    }
}
