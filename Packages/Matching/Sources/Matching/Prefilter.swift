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
    ///   event mentions the project name;
    /// - git recency: a project touched in the last days outranks a dormant
    ///   twin with the same vocabulary;
    /// - an external boost (learned meeting links, call-similarity vectors)
    ///   supplied by the caller.
    public static func score(
        transcriptTokens: [String],
        calendar: CalendarContext?,
        candidate: ProjectCandidate,
        boost: Double = 0,
        now: Date = .now
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
        // Recency only ever nudges a project that already matched on content.
        if score > 0, let activity = candidate.lastGitActivity {
            let days = now.timeIntervalSince(activity) / 86_400
            if days < 2 { score += 2 } else if days < 7 { score += 1 } else if days < 30 { score += 0.5 }
        }
        if score > 0 { score += boost }
        return score
    }

    /// Below this top score the prefilter considers itself weak.
    public static let weakTopScore = 6.0
    /// Second within this fraction of first = a close race.
    public static let closeRaceRatio = 0.75
    /// Shortlist size when the ranking is uncertain (weak or close).
    public static let widenedLimit = 8

    /// Ranks all candidates, returning the best that scored at all. The
    /// shortlist WIDENS automatically when the ranking is uncertain — a weak
    /// winner or a close race — so the true project is less likely to be
    /// dropped before the agent ever sees it.
    public static func rank(
        candidates: [ProjectCandidate],
        transcript: Transcript,
        calendar: CalendarContext?,
        boosts: [String: Double] = [:],
        now: Date = .now,
        limit: Int = 5
    ) -> [ScoredCandidate] {
        let transcriptTokens = tokenize(transcript.attributedText)
        let ranked = candidates
            .map { ScoredCandidate(
                candidate: $0,
                score: score(
                    transcriptTokens: transcriptTokens,
                    calendar: calendar, candidate: $0,
                    boost: boosts[$0.path.path] ?? 0,
                    now: now)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        var effectiveLimit = limit
        if let first = ranked.first {
            let second = ranked.dropFirst().first?.score ?? 0
            if first.score < weakTopScore || second > first.score * closeRaceRatio {
                effectiveLimit = max(limit, widenedLimit)
            }
        }
        return Array(ranked.prefix(effectiveLimit))
    }
}
