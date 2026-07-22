import Core
import Foundation

/// Confidence-gated escalation (issue #7): when the cheap local evidence is
/// decisive — a remembered meeting link, or one dominant candidate that the
/// calendar corroborates — the project is PINNED and the agent only
/// extracts. Agent reasoning about "which project" is paid for only when
/// the prefilter is genuinely uncertain.
public enum EscalationGate {

    public enum Decision: Equatable, Sendable {
        /// Local evidence decided; the agent classifies and extracts only.
        case pinned(ScoredCandidate)
        /// Genuinely uncertain; the agent judges the full shortlist.
        case judge
    }

    /// A learned meeting link may pin even a modest score; a dominant
    /// winner needs calendar agreement so vocabulary luck alone never
    /// skips the judgment.
    public static func decide(
        ranked: [ScoredCandidate],
        calendarAgrees: Bool,
        meetingMappedPath: String?
    ) -> Decision {
        guard let top = ranked.first else { return .judge }
        if let mapped = meetingMappedPath,
           mapped == top.candidate.path.path, top.score >= 4 {
            return .pinned(top)
        }
        guard calendarAgrees else { return .judge }
        let second = ranked.dropFirst().first?.score
        let dominant = if let second {
            top.score >= 10 && top.score >= second * 2.5
        } else {
            top.score >= 8
        }
        return dominant ? .pinned(top) : .judge
    }

    /// Whether the calendar event names the candidate (event terms hit the
    /// project's name tokens).
    public static func calendarAgrees(
        _ calendar: CalendarContext?, with candidate: ProjectCandidate
    ) -> Bool {
        guard let calendar else { return false }
        let calendarTokens = Set(calendar.signalTerms.flatMap { Prefilter.tokenize($0) })
        let nameTokens = Set(Prefilter.tokenize(candidate.name))
        return !calendarTokens.intersection(nameTokens).isEmpty
    }
}
