import Foundation

/// The post-call summary: what Saaa hands you when the call ends.
public struct MeetingSummary: Sendable, Codable, Equatable {

    public struct ActionItem: Sendable, Codable, Equatable, Identifiable, Hashable {
        public var id: UUID
        public var text: String
        public var owner: String?
        public var due: String?
        public var done: Bool

        public init(id: UUID = UUID(), text: String, owner: String? = nil, due: String? = nil, done: Bool = false) {
            self.id = id
            self.text = text
            self.owner = owner.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            self.due = due.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            self.done = done
        }
    }

    public struct Section: Sendable, Codable, Equatable, Identifiable, Hashable {
        public var id: UUID
        public var title: String
        public var bullets: [String]

        public init(id: UUID = UUID(), title: String, bullets: [String]) {
            self.id = id
            self.title = title
            self.bullets = bullets
        }
    }

    public var title: String
    public var tldr: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    /// Playbook-specific sections (Sales: pains, budget...).
    public var sections: [Section]
    public var followUpEmail: String?
    public var generatedAt: Date
    public var model: String

    public init(
        title: String, tldr: String, keyPoints: [String] = [], decisions: [String] = [],
        actionItems: [ActionItem] = [], openQuestions: [String] = [], sections: [Section] = [],
        followUpEmail: String? = nil, generatedAt: Date = .now, model: String = ""
    ) {
        self.title = title
        self.tldr = tldr
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.sections = sections
        self.followUpEmail = followUpEmail.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.generatedAt = generatedAt
        self.model = model
    }

    /// Markdown for copy, save-to-folder and export.
    public func markdown(date: Date? = nil, duration: TimeInterval? = nil, participants: String? = nil) -> String {
        var lines: [String] = ["# \(title)", ""]
        var meta: [String] = []
        if let date { meta.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let duration, duration > 0 { meta.append("\(Int((duration / 60).rounded())) min") }
        if let participants, !participants.isEmpty { meta.append(participants) }
        if !meta.isEmpty { lines += ["_\(meta.joined(separator: " · "))_", ""] }
        if !tldr.isEmpty { lines += ["**TL;DR** \(tldr)", ""] }
        func list(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("## \(heading)")
            lines += items.map { "- \($0)" }
            lines.append("")
        }
        list("Key points", keyPoints)
        list("Decisions", decisions)
        if !actionItems.isEmpty {
            lines.append("## Action items")
            for item in actionItems {
                var line = "- [\(item.done ? "x" : " ")] \(item.text)"
                var tags: [String] = []
                if let owner = item.owner { tags.append(owner) }
                if let due = item.due { tags.append("due \(due)") }
                if !tags.isEmpty { line += " (\(tags.joined(separator: ", ")))" }
                lines.append(line)
            }
            lines.append("")
        }
        list("Open questions", openQuestions)
        for section in sections { list(section.title, section.bullets) }
        if let followUpEmail {
            lines += ["## Follow-up email draft", "", followUpEmail, ""]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// Running notes the copilot keeps during the call.
public struct LiveNotes: Sendable, Codable, Equatable {
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var openQuestions: [String]
    /// Call time (seconds) the notes cover up to.
    public var coveredUntil: TimeInterval
    public var updatedAt: Date

    public init(
        keyPoints: [String] = [], decisions: [String] = [], actionItems: [String] = [],
        openQuestions: [String] = [], coveredUntil: TimeInterval = 0, updatedAt: Date = .now
    ) {
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.coveredUntil = coveredUntil
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty
    }

    /// The notes in the plain heading format the model reads and writes.
    public var plainText: String {
        func block(_ heading: String, _ items: [String]) -> String {
            "\(heading):\n" + (items.isEmpty ? "- (none)" : items.map { "- \($0)" }.joined(separator: "\n"))
        }
        return [
            block("KEY POINTS", keyPoints), block("DECISIONS", decisions),
            block("ACTION ITEMS", actionItems), block("OPEN QUESTIONS", openQuestions),
        ].joined(separator: "\n\n")
    }

    /// Parses the heading format back; tolerant of markdown decoration and
    /// missing sections. Returns nil when nothing recognizable came back.
    public static func parse(_ text: String, coveredUntil: TimeInterval) -> LiveNotes? {
        var notes = LiveNotes(coveredUntil: coveredUntil)
        var current: WritableKeyPath<LiveNotes, [String]>?
        var recognized = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: ")).uppercased()
            switch heading {
            case "KEY POINTS": current = \.keyPoints; recognized = true; continue
            case "DECISIONS": current = \.decisions; recognized = true; continue
            case "ACTION ITEMS": current = \.actionItems; recognized = true; continue
            case "OPEN QUESTIONS": current = \.openQuestions; recognized = true; continue
            default: break
            }
            guard let key = current, line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") else { continue }
            let item = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty, item.lowercased() != "(none)", item.lowercased() != "none" else { continue }
            notes[keyPath: key].append(item)
        }
        return recognized ? notes : nil
    }
}
