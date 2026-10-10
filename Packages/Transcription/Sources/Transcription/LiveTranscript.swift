import Core
import Foundation

/// The live, two-lane transcript of a call: committed (final) segments in
/// time order plus one in-progress partial per lane. Pure value type: the
/// session controller owns it, applies transcriber events, and the copilot
/// reads snapshots.
public struct LiveTranscript: Sendable, Equatable {

    public enum Lane: String, Sendable, Hashable, Codable, CaseIterable {
        case me
        case them

        public var speaker: Speaker {
            switch self {
            case .me: .me
            case .them: .them(label: nil)
            }
        }

        public var label: String {
            switch self {
            case .me: "Me"
            case .them: "Them"
            }
        }
    }

    /// One committed segment with a stable identity for UI diffing.
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: Int
        public let lane: Lane
        public let segment: TranscriptSegment
    }

    /// In-progress words for one lane (replaced, never appended).
    public struct Partial: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
    }

    /// A display line: committed or in-progress.
    public struct Line: Sendable, Equatable, Identifiable {
        public let id: String
        public let lane: Lane
        public let start: TimeInterval
        public let text: String
        public let isFinal: Bool
    }

    /// What a commit did.
    public struct CommitOutcome: Sendable, Equatable {
        /// The new entry, nil when dropped (empty or echo).
        public var added: Entry?
        /// Earlier "Me" entries removed as echoes of this "Them" line.
        public var removedEchoes: Int
        public var droppedAsEcho: Bool
    }

    /// Echoes are matched within this many seconds of each other.
    public static let echoWindow: TimeInterval = 4

    public private(set) var entries: [Entry] = []
    public private(set) var partials: [Lane: Partial] = [:]
    /// Bumped on every change, cheap for observers to compare.
    public private(set) var revision = 0
    /// Echo lines dropped so far (drives the "use headphones" tip).
    public private(set) var echoCount = 0
    public var language: String

    private var nextID = 0

    public init(language: String = "en") {
        self.language = language
    }

    // MARK: - Applying transcriber output

    /// Commits a final phrase for `lane`, applying the echo guard.
    @discardableResult
    public mutating func commit(
        _ lane: Lane, start: TimeInterval, end: TimeInterval, text: String, confidence: Float = 1
    ) -> CommitOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clearPartialIfCovered(lane, through: end)
        guard !trimmed.isEmpty else {
            revision += 1
            return CommitOutcome(added: nil, removedEchoes: 0, droppedAsEcho: false)
        }
        var removed = 0
        switch lane {
        case .me:
            // Your mic heard their speakers: the Them lane already has it.
            if entries.contains(where: { $0.lane == .them && Self.isEcho(trimmed, start, of: $0.segment) }) {
                echoCount += 1
                revision += 1
                return CommitOutcome(added: nil, removedEchoes: 0, droppedAsEcho: true)
            }
        case .them:
            // The Me lane finalized the echo first: retract it.
            let before = entries.count
            entries.removeAll { $0.lane == .me && Self.isEcho($0.segment.text, $0.segment.start, ofText: trimmed, start: start) }
            removed = before - entries.count
            echoCount += removed
        }
        let entry = Entry(
            id: nextID, lane: lane,
            segment: TranscriptSegment(
                speaker: lane.speaker, start: start, end: max(end, start), text: trimmed,
                confidence: confidence))
        nextID += 1
        insertOrdered(entry)
        revision += 1
        return CommitOutcome(added: entry, removedEchoes: removed, droppedAsEcho: false)
    }

    /// Replaces `lane`'s in-progress words.
    public mutating func setPartial(_ lane: Lane, start: TimeInterval, end: TimeInterval, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            partials[lane] = nil
        } else {
            partials[lane] = Partial(start: start, end: end, text: trimmed)
        }
        revision += 1
    }

    public mutating func clearPartials() {
        partials.removeAll()
        revision += 1
    }

    // MARK: - Reading

    /// Committed lines plus in-progress partials, in time order.
    public var lines: [Line] {
        var result = entries.map {
            Line(id: "c\($0.id)", lane: $0.lane, start: $0.segment.start, text: $0.segment.text, isFinal: true)
        }
        for lane in Lane.allCases {
            if let partial = partials[lane] {
                result.append(Line(id: "p-\(lane.rawValue)", lane: lane, start: partial.start, text: partial.text, isFinal: false))
            }
        }
        return result.sorted { lhs, rhs in
            lhs.start == rhs.start ? (lhs.isFinal && !rhs.isFinal) : lhs.start < rhs.start
        }
    }

    /// The last `count` display lines.
    public func recentLines(_ count: Int) -> [Line] {
        Array(lines.suffix(count))
    }

    /// Committed entries that started before `cutoff`: a stable prefix once
    /// both lanes have finalized past it (prompt-cache chunks are built
    /// only from this prefix).
    public func settled(before cutoff: TimeInterval) -> ArraySlice<Entry> {
        let end = entries.firstIndex { $0.segment.start >= cutoff } ?? entries.endIndex
        return entries[..<end]
    }

    /// Committed entries from `cutoff` on (not yet settled).
    public func unsettled(from cutoff: TimeInterval) -> ArraySlice<Entry> {
        let start = entries.firstIndex { $0.segment.start >= cutoff } ?? entries.endIndex
        return entries[start...]
    }

    /// Seconds of audio covered so far.
    public var duration: TimeInterval {
        max(entries.map(\.segment.end).max() ?? 0, partials.values.map(\.end).max() ?? 0)
    }

    /// The final Me/Them transcript.
    public var transcript: Transcript {
        Transcript(segments: entries.map(\.segment), language: language)
    }

    /// Speaking time per lane from committed segments.
    public var talkTime: (me: TimeInterval, them: TimeInterval) {
        var me: TimeInterval = 0
        var them: TimeInterval = 0
        for entry in entries {
            let span = max(0, entry.segment.end - entry.segment.start)
            if entry.lane == .me { me += span } else { them += span }
        }
        return (me, them)
    }

    /// Plain `Me:`/`Them:` text of committed lines.
    public var plainText: String {
        entries.map { "\($0.lane.label): \($0.segment.text)" }.joined(separator: "\n")
    }

    // MARK: - Internals

    private mutating func clearPartialIfCovered(_ lane: Lane, through end: TimeInterval) {
        if let partial = partials[lane], partial.end <= end + 0.05 {
            partials[lane] = nil
        }
    }

    private mutating func insertOrdered(_ entry: Entry) {
        let start = entry.segment.start
        if let last = entries.last, last.segment.start > start {
            let index = entries.lastIndex { $0.segment.start <= start }.map { $0 + 1 } ?? 0
            entries.insert(entry, at: index)
        } else {
            entries.append(entry)
        }
    }

    static func isEcho(_ text: String, _ start: TimeInterval, of other: TranscriptSegment) -> Bool {
        isEcho(text, start, ofText: other.text, start: other.start)
    }

    static func isEcho(_ text: String, _ start: TimeInterval, ofText other: String, start otherStart: TimeInterval) -> Bool {
        guard abs(start - otherStart) <= echoWindow else { return false }
        return TextSimilarity.isNearDuplicate(text, other)
    }
}
