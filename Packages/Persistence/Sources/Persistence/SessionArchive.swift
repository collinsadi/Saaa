import ClaudeBridge
import Core
import Foundation
import Matching

/// One Live Assist exchange as sealed content: a plain-data mirror of the
/// call-time thread (mode kept as a display string so Persistence stays free
/// of agent-layer types).
public struct AssistThreadEntry: Sendable, Codable, Equatable {
    /// "ask" | "answer".
    public var role: String
    /// The mode's display name, answers only.
    public var mode: String?
    public var text: String
    public var at: Date

    public init(role: String, mode: String?, text: String, at: Date) {
        self.role = role
        self.mode = mode
        self.text = text
        self.at = at
    }
}

/// Everything content-bearing from one call, sealed into a single encrypted
/// file (`session.enc`) beside the session's other artifacts.
public struct SessionArchive: Sendable, Codable {
    public var transcript: Transcript
    public var calendar: CalendarContext?
    public var matches: [ScoredCandidate]
    public var judgment: CallJudgment?
    /// User corrections + write-back outcomes, appended over time.
    public var notes: [String]
    /// The Live Assist thread, when the call ran with the copilot on.
    /// Optional so pre-thread archives decode unchanged.
    public var assistThread: [AssistThreadEntry]?

    public init(
        transcript: Transcript,
        calendar: CalendarContext?,
        matches: [ScoredCandidate],
        judgment: CallJudgment?,
        notes: [String] = [],
        assistThread: [AssistThreadEntry]? = nil
    ) {
        self.transcript = transcript
        self.calendar = calendar
        self.matches = matches
        self.judgment = judgment
        self.notes = notes
        self.assistThread = assistThread
    }
}
