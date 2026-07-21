import Core
import Foundation

/// The cheap local prefilter: scores every candidate project against the
/// transcript (term overlap) with a calendar boost, keeping the top few for
/// Claude Code's judgment. Pure and deterministic.
public enum Prefilter {

    /// Minimal stopword set — just enough to stop conversational glue from
    /// dominating the overlap.
    static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "have",
        "was", "were", "are", "but", "not", "can", "will", "just", "like",
        "yeah", "okay", "about", "there", "what", "when", "then", "they",
        "them", "going", "think", "know", "want", "need", "from", "into",
        "some", "more", "here", "also", "well", "right", "good", "get",
    ]

    /// Lowercased content tokens of length ≥ 3, camelCase split.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        for raw in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            // Split camelCase / PascalCase identifiers into their words.
            var current = ""
            var pieces: [String] = []
            for character in raw {
                if character.isUppercase && !current.isEmpty
                    && current.last?.isLowercase == true {
                    pieces.append(current)
                    current = ""
                }
                current.append(character)
            }
            pieces.append(current)
            if pieces.count > 1 { tokens.append(String(raw).lowercased()) }
            tokens += pieces.map { $0.lowercased() }
        }
        return tokens.filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// Scores one candidate. Components:
    /// - term overlap between transcript and profile, dampened by profile
    ///   size (√) so huge repos don't win on vocabulary breadth alone;
    /// - a strong bonus when the project's NAME is spoken;
    /// - calendar boost: event terms matching the profile, extra when the
    ///   event mentions the project name.
    public static func score(
        transcriptTokens: [String],
        calendar: CalendarContext?,
        candidate: ProjectCandidate
    ) -> Double {
        let transcript = Set(transcriptTokens)
        guard !transcript.isEmpty else { return 0 }
        let profile = Set(candidate.profileTerms.flatMap { tokenize($0) })
        guard !profile.isEmpty else { return 0 }
        let nameTokens = Set(tokenize(candidate.name))

        var score = Double(transcript.intersection(profile).count)
            / (Double(profile.count).squareRoot())
        score += Double(transcript.intersection(nameTokens).count) * 3

        if let calendar {
            let calendarTokens = Set(calendar.signalTerms.flatMap { tokenize($0) })
            score += Double(calendarTokens.intersection(profile).count) * 2
            score += Double(calendarTokens.intersection(nameTokens).count) * 5
        }
        return score
    }

    /// Ranks all candidates, returning the `limit` best that scored at all.
    public static func rank(
        candidates: [ProjectCandidate],
        transcript: Transcript,
        calendar: CalendarContext?,
        limit: Int = 5
    ) -> [ScoredCandidate] {
        let transcriptTokens = tokenize(transcript.attributedText)
        return candidates
            .map { ScoredCandidate(
                candidate: $0,
                score: score(
                    transcriptTokens: transcriptTokens,
                    calendar: calendar, candidate: $0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
