import Foundation

/// How the copilot behaves for one kind of conversation: who you are on the
/// call, what quick actions you get, which words to listen for, reference
/// material, and what the summary should contain.
public struct Playbook: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    public var tint: PlaybookTint
    /// One line for pickers.
    public var tagline: String
    /// The role and how to help, in the user's words.
    public var instructions: String
    public var quickActions: [QuickAction]
    /// Names, products and jargon: biases transcription and grounds answers.
    public var vocabulary: [String]
    public var knowledge: [KnowledgeItem]
    /// Extra summary sections beyond TL;DR, decisions, actions, questions.
    public var summarySections: [String]
    public var draftsFollowUpEmail: Bool
    /// Answer the other side's questions automatically.
    public var autoSuggest: Bool
    /// Keep running notes during the call.
    public var liveNotes: Bool
    /// Calendar-title words that pick this playbook ("demo", "interview").
    public var titleKeywords: [String]
    public var isBuiltIn: Bool
    public var updatedAt: Date

    public init(
        id: String, name: String, symbol: String, tint: PlaybookTint, tagline: String,
        instructions: String, quickActions: [QuickAction], vocabulary: [String] = [],
        knowledge: [KnowledgeItem] = [], summarySections: [String] = [],
        draftsFollowUpEmail: Bool = false, autoSuggest: Bool = false, liveNotes: Bool = true,
        titleKeywords: [String] = [], isBuiltIn: Bool = false, updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.tagline = tagline
        self.instructions = instructions
        self.quickActions = quickActions
        self.vocabulary = vocabulary
        self.knowledge = knowledge
        self.summarySections = summarySections
        self.draftsFollowUpEmail = draftsFollowUpEmail
        self.autoSuggest = autoSuggest
        self.liveNotes = liveNotes
        self.titleKeywords = titleKeywords
        self.isBuiltIn = isBuiltIn
        self.updatedAt = updatedAt
    }

    /// An editable copy that is no longer a built-in.
    public func duplicated(named newName: String? = nil) -> Playbook {
        var copy = self
        copy.id = "custom.\(UUID().uuidString)"
        copy.name = newName ?? "\(name) copy"
        copy.isBuiltIn = false
        copy.updatedAt = .now
        return copy
    }

    /// Total characters of knowledge (prompt budget display).
    public var knowledgeCharacters: Int {
        knowledge.reduce(0) { $0 + $1.text.count }
    }
}

/// Accent families for playbooks; the design system maps them to colors.
public enum PlaybookTint: String, Sendable, Codable, CaseIterable, Hashable {
    case tide, ember, violet, green, rose, amber, slate, sky
}

/// One-tap copilot task.
public struct QuickAction: Sendable, Codable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// Answers the latest question: auto-suggest uses the first of these.
        case answer
        case say
        case ask
        case recap
        case custom
    }

    public var id: String
    public var title: String
    public var symbol: String
    /// The task given to the model.
    public var instruction: String
    public var kind: Kind

    public init(id: String, title: String, symbol: String, instruction: String, kind: Kind) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.instruction = instruction
        self.kind = kind
    }
}

/// Reference text the copilot may cite: pricing sheet, product FAQ,
/// interview rubric. Stored extracted (plain text) and encrypted.
public struct KnowledgeItem: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var text: String
    public var addedAt: Date

    /// Per-item cap keeps one file from eating the prompt.
    public static let maxCharacters = 120_000

    public init(id: UUID = UUID(), name: String, text: String, addedAt: Date = .now) {
        self.id = id
        self.name = name
        self.text = String(text.prefix(Self.maxCharacters))
        self.addedAt = addedAt
    }
}

/// Picks a playbook for a meeting title from each playbook's keywords.
public enum PlaybookMatcher {
    public static func match(title: String, in playbooks: [Playbook]) -> Playbook? {
        let lowered = title.lowercased()
        let words = Set(lowered.split { !$0.isLetter && !$0.isNumber && $0 != ":" && $0 != "-" }.map(String.init))
        var best: (playbook: Playbook, score: Int)?
        for playbook in playbooks {
            var score = 0
            for keyword in playbook.titleKeywords {
                let key = keyword.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                if key.contains(" ") || key.contains(":") {
                    if lowered.contains(key) { score += 2 }
                } else if words.contains(key) {
                    score += 2
                } else if lowered.contains(key), key.count >= 5 {
                    score += 1
                }
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (playbook, score)
            }
        }
        return best?.playbook
    }
}
