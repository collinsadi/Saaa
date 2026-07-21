import Foundation

/// Builds whisper's `initial_prompt` from project vocabulary (repo names,
/// symbols, client names, domain jargon) so proper nouns transcribe
/// correctly — a cheap, large accuracy win.
public enum VocabularyBias {

    /// Renders `terms` into a prompt, deduplicated case-insensitively with
    /// order preserved, capped at `maxLength` characters on a term boundary.
    /// Returns `nil` when there is nothing to bias with.
    ///
    /// The prompt reads as preceding conversation context (that is how
    /// whisper conditions on it), so it is phrased as prose, not a list dump.
    public static func initialPrompt(terms: [String], maxLength: Int = 800) -> String? {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            kept.append(term)
        }
        guard !kept.isEmpty else { return nil }

        let prefix = "This call may mention: "
        var prompt = prefix
        for (index, term) in kept.enumerated() {
            let addition = index == 0 ? term : ", \(term)"
            guard prompt.count + addition.count <= maxLength - 1 else { break }
            prompt += addition
        }
        guard prompt.count > prefix.count else { return nil }
        return prompt + "."
    }
}
