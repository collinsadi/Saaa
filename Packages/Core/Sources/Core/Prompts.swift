import Foundation

/// Custom prompts (issue #2): user-authored steering for transcription
/// (vocabulary) and filing (instructions), scoped with clear precedence:
/// global, then per project, then per call type, then next-call-only.

public enum PromptKind: String, CaseIterable, Sendable, Codable {
    /// Primes Whisper toward correct proper nouns and spellings.
    case vocabulary
    /// Shapes matching and extraction (format, focus, house style).
    case filing
    /// Context for the Live Assist copilot (issue #8): what the user
    /// supports, where the knowledge lives, how answers should sound.
    /// Live Assist requires this to be set before it arms.
    case liveAssist = "live_assist"
}

/// Where a prompt applies. Raw storage keys are stable; never rename.
public enum PromptScope: Hashable, Sendable, Codable {
    case global
    case project(path: String)
    /// technical | client_preference | standup | other
    case callType(String)
    /// One-time: consumed by the next processed call.
    case nextCall
}

public enum PromptResolver {

    /// Layers filing instructions in precedence order, most specific LAST
    /// so it reads as the final word. Call-type blocks are conditional:
    /// the agent classifies the call itself, so every block ships labeled
    /// and the agent applies the one that matches its own classification.
    public static func composeFiling(
        global: String?,
        project: String?,
        callTypeBlocks: [String: String],
        nextCall: String?
    ) -> String? {
        var sections: [String] = []
        if let text = clean(global) {
            sections.append(text)
        }
        if let text = clean(project) {
            sections.append("For this project specifically:\n\(text)")
        }
        for (type, block) in callTypeBlocks.sorted(by: { $0.key < $1.key }) {
            if let text = clean(block) {
                sections.append("Only if you classify this call as \(type):\n\(text)")
            }
        }
        if let text = clean(nextCall) {
            sections.append("For THIS call only (one-time, highest priority):\n\(text)")
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    /// Vocabulary text is free-form (commas or newlines); terms come out
    /// trimmed and deduplicated case-insensitively, order preserved,
    /// earliest source first so more specific scopes should be passed last.
    public static func vocabularyTerms(_ texts: [String?]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for text in texts {
            guard let text else { continue }
            for raw in text.split(whereSeparator: { $0 == "," || $0.isNewline }) {
                let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
                terms.append(term)
            }
        }
        return terms
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// `{project}`, `{attendees}`, `{date}` substitution at use time.
public enum PromptTemplate {
    public static func render(
        _ text: String, project: String?, attendees: [String], date: Date
    ) -> String {
        text
            .replacingOccurrences(of: "{project}", with: project ?? "the matched project")
            .replacingOccurrences(
                of: "{attendees}",
                with: attendees.isEmpty ? "unknown attendees" : attendees.joined(separator: ", "))
            .replacingOccurrences(
                of: "{date}", with: date.formatted(date: .abbreviated, time: .omitted))
    }
}

/// Editable starting points for filing instructions. Inserted, never
/// enforced; the user owns the text from there.
public struct PromptPreset: Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The call-type scope the preset is written for.
    public let callType: String
    public let text: String

    public static let all: [PromptPreset] = [
        PromptPreset(
            id: "client-call", name: "Client call", callType: "client_preference",
            text: """
            Capture every wish, constraint, and objection from the client verbatim where wording matters. \
            Attribute each preference to who said it ({attendees}). Flag anything that changes scope, \
            budget, or deadline as a risk. Keep bodies short and decision-first.
            """),
        PromptPreset(
            id: "technical-design", name: "Technical design", callType: "technical",
            text: """
            Record decisions WITH their rationale and the alternatives that were rejected. \
            Write data models and API shapes as code blocks. Note open questions as action items \
            with an owner. Prefer precise identifiers from {project} over prose descriptions.
            """),
        PromptPreset(
            id: "standup", name: "Standup", callType: "standup",
            text: """
            Extract only: status per person, blockers, and action items with owners and dates. \
            No summaries of discussion. One line per item. Skip anything that is not a commitment \
            or a blocker.
            """),
    ]
}
