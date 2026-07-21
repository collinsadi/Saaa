import Foundation

/// The calendar event overlapping a call — a strong matching signal (a title
/// like "Acme Corp — API integration" often identifies the project outright)
/// and a source of Whisper vocabulary.
public struct CalendarContext: Sendable, Equatable, Codable {
    public var title: String
    /// Attendee display names and/or email addresses.
    public var attendees: [String]
    public var notes: String?

    public init(title: String, attendees: [String], notes: String? = nil) {
        self.title = title
        self.attendees = attendees
        self.notes = notes
    }

    /// Tokens worth feeding to the matching prefilter and Whisper bias.
    public var signalTerms: [String] {
        var terms = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for attendee in attendees {
            // "jane@acme.com" contributes "jane" and "acme"; names contribute words.
            terms += attendee
                .split(whereSeparator: { "@. ".contains($0) })
                .map(String.init)
                .filter { $0.lowercased() != "com" && $0.count > 2 }
        }
        return terms
    }
}
