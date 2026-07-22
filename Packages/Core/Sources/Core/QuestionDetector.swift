import Foundation

/// Cheap local heuristic for Live Assist auto-trigger (issue #8): does the
/// other side's latest utterance look like a question aimed at the user?
/// Deliberately conservative — the hotkey is the primary trigger and false
/// positives cost an agent call.
public enum QuestionDetector {

    private static let openers = [
        "what", "how", "why", "when", "where", "who", "which",
        "can you", "could you", "would you", "will you", "do you",
        "does", "is there", "are there", "tell me", "walk me",
    ]

    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 8 else { return false }
        if trimmed.hasSuffix("?") { return true }
        return openers.contains { trimmed.hasPrefix($0 + " ") }
    }
}
