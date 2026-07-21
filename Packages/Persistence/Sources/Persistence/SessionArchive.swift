import ClaudeBridge
import Core
import Foundation
import Matching

/// Everything content-bearing from one call, sealed into a single encrypted
/// file (`session.enc`) beside the session's other artifacts.
public struct SessionArchive: Sendable, Codable {
    public var transcript: Transcript
    public var calendar: CalendarContext?
    public var matches: [ScoredCandidate]
    public var judgment: CallJudgment?
    /// User corrections + write-back outcomes, appended over time.
    public var notes: [String]

    public init(
        transcript: Transcript,
        calendar: CalendarContext?,
        matches: [ScoredCandidate],
        judgment: CallJudgment?,
        notes: [String] = []
    ) {
        self.transcript = transcript
        self.calendar = calendar
        self.matches = matches
        self.judgment = judgment
        self.notes = notes
    }
}
