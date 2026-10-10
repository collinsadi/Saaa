import Core
import Foundation

/// Everything one session produced, sealed into `session.enc`.
public struct SessionRecord: Sendable, Codable, Equatable, Identifiable {

    public enum Source: String, Sendable, Codable {
        /// Recorded live with Saaa.
        case live
        /// An imported audio or video file.
        case imported
        /// Migrated from a pre-rebuild version of Saaa.
        case legacy
    }

    public static let currentVersion = 2

    public var version: Int
    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    public var title: String
    public var playbookID: String
    public var playbookName: String
    public var context: SessionContext
    public var transcript: Transcript
    public var thread: [CopilotExchange]
    public var notes: LiveNotes?
    public var summary: MeetingSummary?
    public var chat: [ChatTurn]
    public var usage: UsageLedger
    public var source: Source
    public var audioRetained: Bool

    public init(
        id: UUID = UUID(), startedAt: Date, duration: TimeInterval, title: String,
        playbookID: String, playbookName: String, context: SessionContext = SessionContext(),
        transcript: Transcript, thread: [CopilotExchange] = [], notes: LiveNotes? = nil,
        summary: MeetingSummary? = nil, chat: [ChatTurn] = [], usage: UsageLedger = UsageLedger(),
        source: Source = .live, audioRetained: Bool = false
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.title = title
        self.playbookID = playbookID
        self.playbookName = playbookName
        self.context = context
        self.transcript = transcript
        self.thread = thread
        self.notes = notes
        self.summary = summary
        self.chat = chat
        self.usage = usage
        self.source = source
        self.audioRetained = audioRetained
    }

    /// The title to show: summary title, else the session title, else a date.
    public var displayTitle: String {
        if let title = summary?.title.trimmingCharacters(in: .whitespaces), !title.isEmpty { return title }
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return "Call · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Copy-ready Markdown: the summary when there is one, then the transcript.
    public func markdown(includeTranscript: Bool = true) -> String {
        var text: String
        if let summary {
            text = summary.markdown(date: startedAt, duration: duration, participants: context.participants)
        } else {
            text = "# \(displayTitle)\n\n_\(startedAt.formatted(date: .abbreviated, time: .shortened))_\n"
        }
        if includeTranscript, !transcript.segments.isEmpty {
            text += "\n## Transcript\n\n"
            text += transcript.segments.map { segment in
                let who: String = switch segment.speaker {
                case .me: "Me"
                case .them(let label): label ?? "Them"
                }
                return "**\(who)** [\(CallTime.stamp(segment.start))] \(segment.text)"
            }.joined(separator: "\n\n")
            text += "\n"
        }
        return text
    }
}

/// One row of the library index: enough to list, filter and search sessions
/// without decrypting every archive.
public struct SessionIndexEntry: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    public var title: String
    public var playbookID: String
    public var playbookName: String
    public var tldr: String
    public var openActionItems: Int
    public var hasSummary: Bool
    public var costUSD: Double
    /// Folder name under `Sessions/`.
    public var folder: String
    public var source: SessionRecord.Source

    public init(record: SessionRecord, folder: String) {
        id = record.id
        startedAt = record.startedAt
        duration = record.duration
        title = record.displayTitle
        playbookID = record.playbookID
        playbookName = record.playbookName
        tldr = record.summary?.tldr ?? ""
        openActionItems = record.summary?.actionItems.filter { !$0.done }.count ?? 0
        hasSummary = record.summary != nil
        costUSD = record.usage.totalCostUSD
        self.folder = folder
        source = record.source
    }

    /// Case-insensitive match on title, playbook and TL;DR.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return [title, playbookName, tldr].contains { $0.lowercased().contains(needle) }
    }
}
