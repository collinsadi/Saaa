import Foundation

/// What the user tells Saaa before (or during) a session. Every field is
/// optional; the calendar pre-fills title, participants and notes.
public struct SessionContext: Sendable, Codable, Equatable {
    public var title: String
    public var goal: String
    /// Free text: "Dana (Acme, CFO), Ken (procurement)".
    public var participants: String
    /// Agenda, background, links.
    public var notes: String

    public init(title: String = "", goal: String = "", participants: String = "", notes: String = "") {
        self.title = title
        self.goal = goal
        self.participants = participants
        self.notes = notes
    }

    public var isEmpty: Bool {
        [title, goal, participants, notes].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Pre-fill from the calendar event overlapping the call.
    public static func from(_ calendar: CalendarContext) -> SessionContext {
        SessionContext(
            title: calendar.title,
            participants: calendar.attendees.joined(separator: ", "),
            notes: calendar.notes ?? "")
    }

    /// Fills empty fields from `other` without overwriting what the user typed.
    public func filling(from other: SessionContext) -> SessionContext {
        func pick(_ mine: String, _ theirs: String) -> String {
            mine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theirs : mine
        }
        return SessionContext(
            title: pick(title, other.title),
            goal: pick(goal, other.goal),
            participants: pick(participants, other.participants),
            notes: pick(notes, other.notes))
    }

    /// Names worth biasing transcription toward (participants + title words).
    public var vocabularyHints: [String] {
        var terms: [String] = []
        for raw in participants.split(whereSeparator: { ",;\n".contains($0) }) {
            let name = raw.split(separator: "(").first.map(String.init) ?? String(raw)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 1, !trimmed.contains("@") { terms.append(trimmed) }
        }
        for word in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count > 3 {
            if word.first?.isUppercase == true { terms.append(String(word)) }
        }
        return terms
    }
}
