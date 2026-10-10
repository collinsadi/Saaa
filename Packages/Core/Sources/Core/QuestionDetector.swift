import Foundation

/// Cheap local check: does the other side's latest phrase look like a
/// question aimed at the user? Gates auto-suggest, so it is conservative:
/// a false positive costs an answer nobody asked for.
public enum QuestionDetector {

    private static let openers = [
        "what", "what's", "whats", "how", "how's", "why", "when", "where", "who", "who's", "which",
        "can you", "could you", "would you", "will you", "do you", "did you", "have you",
        "are you", "is there", "are there", "is it", "does", "should we", "should i",
        "tell me", "walk me", "help me understand", "i'm curious", "i was wondering",
        "any thoughts", "thoughts on",
    ]

    /// Tag questions that don't need an answer ("right?", "you know?").
    private static let fillerEndings = ["right?", "you know?", "okay?", "ok?", "yeah?", "huh?", "no?", "correct?"]

    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard trimmed.count >= 10, words.count >= 3 else { return false }
        if trimmed.hasSuffix("?") {
            // "We're good, right?" is a check-in, not a question to answer.
            if words.count <= 6, fillerEndings.contains(where: { trimmed.hasSuffix(" " + $0) }) {
                return false
            }
            return true
        }
        return openers.contains { trimmed.hasPrefix($0 + " ") }
    }

    /// The question-like sentence inside a longer phrase, if any (the last
    /// one wins: people ask after context).
    public static func extractQuestion(_ text: String) -> String? {
        let sentences = text
            .split(omittingEmptySubsequences: true) { ".!?".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var cursor = text.startIndex
        var found: String?
        for sentence in sentences {
            guard let range = text.range(of: sentence, range: cursor..<text.endIndex) else { continue }
            cursor = range.upperBound
            let terminated = cursor < text.endIndex && text[cursor] == "?"
            let candidate = terminated ? sentence + "?" : sentence
            if looksLikeQuestion(candidate) { found = candidate }
        }
        return found
    }
}
