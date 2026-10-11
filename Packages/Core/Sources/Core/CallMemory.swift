import Foundation

/// One past session as Memory reads it, decrypted on the Mac.
public struct MemorySource: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var playbookName: String
    public var participants: String
    /// Summary lines: TL;DR, key points, decisions, action items with owners,
    /// open questions, playbook sections and checklist evidence.
    public var summary: [String]
    /// What the user wrote before the call: goal and notes.
    public var prep: [String]
    public var segments: [TranscriptSegment]

    public init(
        id: UUID, title: String, startedAt: Date, playbookName: String = "", participants: String = "",
        summary: [String] = [], prep: [String] = [], segments: [TranscriptSegment] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.playbookName = playbookName
        self.participants = participants
        self.summary = summary
        self.prep = prep
        self.segments = segments
    }
}

/// A searchable piece of a past call: part of its summary, the prep notes,
/// or a few lines of transcript.
public struct MemoryChunk: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case summary, prep, transcript
    }

    public let id: Int
    public let sessionID: UUID
    public let kind: Kind
    public let text: String
    /// Call time of the first line, for transcript chunks.
    public let callTime: TimeInterval?
}

/// A chunk that matched, with its session's details for citing.
public struct MemoryExcerpt: Sendable, Equatable, Identifiable {
    public let chunk: MemoryChunk
    public let title: String
    public let startedAt: Date
    public let playbookName: String
    public let score: Double

    public var id: Int { chunk.id }
    public var sessionID: UUID { chunk.sessionID }
}

/// Search over past calls, built and run on the Mac: BM25 over summary,
/// prep and transcript chunks, with each session's title and participants
/// counted in every chunk so "what did Acme say about pricing" finds the
/// Acme calls. Nothing here sends anything; the caller decides what goes
/// to Claude.
public struct MemoryIndex: Sendable {

    /// A transcript chunk closes at this many characters or lines.
    static let chunkCharacters = 700
    static let chunkLines = 8
    /// Lines repeated at the start of the next chunk, so a moment split
    /// across two chunks still reads whole in one.
    static let overlapLines = 2
    static let summaryChunkCharacters = 1_200

    static let k1 = 1.2
    static let b = 0.75

    public let chunks: [MemoryChunk]
    private let sessions: [UUID: MemorySource]
    private let termCounts: [[String: Int]]
    private let lengths: [Int]
    private let postings: [String: [Int]]
    private let averageLength: Double

    public var sessionCount: Int { sessions.count }
    public var isEmpty: Bool { chunks.isEmpty }

    public init(sources: [MemorySource]) {
        var chunks: [MemoryChunk] = []
        var termCounts: [[String: Int]] = []
        var lengths: [Int] = []
        var postings: [String: [Int]] = [:]
        var sessions: [UUID: MemorySource] = [:]
        for source in sources {
            sessions[source.id] = source
            let shared = Self.tokens(source.title + " " + source.participants + " " + source.playbookName)
            for piece in Self.pieces(of: source) {
                let index = chunks.count
                chunks.append(MemoryChunk(id: index, sessionID: source.id, kind: piece.kind, text: piece.text, callTime: piece.callTime))
                var counts: [String: Int] = [:]
                let words = Self.tokens(piece.text) + shared
                for word in words { counts[word, default: 0] += 1 }
                for word in counts.keys { postings[word, default: []].append(index) }
                termCounts.append(counts)
                lengths.append(words.count)
            }
        }
        self.chunks = chunks
        self.sessions = sessions
        self.termCounts = termCounts
        self.lengths = lengths
        self.postings = postings
        self.averageLength = lengths.isEmpty ? 1 : Double(lengths.reduce(0, +)) / Double(lengths.count)
    }

    /// The excerpts most worth sending for `query`, oldest call first so
    /// they read in order. A time phrase ("last week") narrows the calls;
    /// with no word in common, the newest summaries in range stand in.
    public func search(
        _ query: String, limit: Int = 24, perSession: Int = 6, characterBudget: Int = 24_000,
        now: Date = .now, calendar: Calendar = .current
    ) -> [MemoryExcerpt] {
        let range = MemoryTimeFilter.range(in: query, now: now, calendar: calendar)
        let inRange: (UUID) -> Bool = { id in
            guard let range, let source = sessions[id] else { return true }
            return range.contains(source.startedAt)
        }
        var scores: [Int: Double] = [:]
        let terms = Set(Self.tokens(query))
        let count = Double(chunks.count)
        for term in terms {
            guard let hits = postings[term] else { continue }
            let idf = log(1 + (count - Double(hits.count) + 0.5) / (Double(hits.count) + 0.5))
            for index in hits where inRange(chunks[index].sessionID) {
                let frequency = Double(termCounts[index][term] ?? 0)
                let norm = Self.k1 * (1 - Self.b + Self.b * Double(lengths[index]) / averageLength)
                scores[index, default: 0] += idf * frequency * (Self.k1 + 1) / (frequency + norm)
            }
        }
        var ranked: [(index: Int, score: Double)] = scores.map { index, score in
            let chunk = chunks[index]
            var boosted = score
            if chunk.kind == .summary { boosted *= 1.25 }
            if let started = sessions[chunk.sessionID]?.startedAt {
                let days = max(0, now.timeIntervalSince(started) / 86_400)
                boosted *= 1 + 0.15 * exp(-days / 30)
            }
            return (index, boosted)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }

        if ranked.isEmpty {
            // Nothing in common: the newest summaries (in range) answer
            // "what happened recently" questions.
            let recent = sessions.values.filter { inRange($0.id) }.sorted { $0.startedAt > $1.startedAt }.prefix(8)
            let ids = Set(recent.map(\.id))
            ranked = chunks.filter { $0.kind == .summary && ids.contains($0.sessionID) }.map { ($0.id, 0) }
        }

        var picked: [MemoryExcerpt] = []
        var perSessionCount: [UUID: Int] = [:]
        var characters = 0
        for (index, score) in ranked {
            guard picked.count < limit else { break }
            let chunk = chunks[index]
            guard perSessionCount[chunk.sessionID, default: 0] < perSession,
                  characters + chunk.text.count <= characterBudget,
                  let source = sessions[chunk.sessionID] else { continue }
            perSessionCount[chunk.sessionID, default: 0] += 1
            characters += chunk.text.count
            picked.append(MemoryExcerpt(
                chunk: chunk, title: source.title, startedAt: source.startedAt,
                playbookName: source.playbookName, score: score))
        }
        return picked.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.chunk.kind != $1.chunk.kind { return $0.chunk.kind == .summary }
            return ($0.chunk.callTime ?? 0) < ($1.chunk.callTime ?? 0)
        }
    }

    // MARK: - Chunking

    struct Piece: Equatable {
        var kind: MemoryChunk.Kind
        var text: String
        var callTime: TimeInterval?
    }

    static func pieces(of source: MemorySource) -> [Piece] {
        var pieces: [Piece] = []
        pieces += grouped(source.summary, limit: summaryChunkCharacters).map { Piece(kind: .summary, text: $0) }
        pieces += grouped(source.prep, limit: summaryChunkCharacters).map { Piece(kind: .prep, text: $0) }
        let lines = source.segments.sorted { $0.start < $1.start }.compactMap { segment -> (String, TimeInterval)? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = switch segment.speaker {
            case .me: "Me"
            case .them(let label): label ?? "Them"
            }
            return ("\(who): \(text)", segment.start)
        }
        var start = 0
        while start < lines.count {
            var end = start
            var characters = 0
            while end < lines.count, end - start < chunkLines, characters < chunkCharacters {
                characters += lines[end].0.count
                end += 1
            }
            pieces.append(Piece(kind: .transcript, text: lines[start..<end].map(\.0).joined(separator: "\n"), callTime: lines[start].1))
            if end >= lines.count { break }
            start = max(start + 1, end - overlapLines)
        }
        return pieces
    }

    /// Lines packed into chunks of about `limit` characters.
    static func grouped(_ lines: [String], limit: Int) -> [String] {
        var groups: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
            if size + line.count > limit, !current.isEmpty {
                groups.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { groups.append(current.joined(separator: "\n")) }
        return groups
    }

    // MARK: - Words

    static let stopwords: Set<String> = [
        "a", "about", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at", "be", "been", "before",
        "but", "by", "can", "could", "did", "do", "does", "doing", "for", "from", "had", "has", "have", "how", "i",
        "if", "in", "into", "is", "it", "its", "just", "me", "my", "no", "not", "of", "on", "or", "our", "out", "over",
        "said", "say", "says", "so", "some", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "to", "up", "us", "was", "we", "were", "what", "when", "where", "which", "who", "why", "will", "with",
        "would", "you", "your", "call", "calls", "week", "month", "last", "today", "yesterday", "recently", "ago",
        "tell", "told", "talk", "talked", "anything", "something", "ever",
    ]

    /// Lowercased words without stopwords, lightly stemmed so "prices"
    /// meets "price" and "renewing" meets "renew".
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopwords.contains($0) && ($0.count > 1 || $0.first?.isNumber == true) }
            .map(stem)
    }

    static func stem(_ word: String) -> String {
        var word = word
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 5, word.hasSuffix("ing") { word = String(word.dropLast(3)) }
        else if word.count > 4, word.hasSuffix("ed") { word = String(word.dropLast(2)) }
        else if word.count > 4, ["ses", "xes", "zes", "ches", "shes"].contains(where: word.hasSuffix) { word = String(word.dropLast(2)) }
        else if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { word = String(word.dropLast()) }
        // "pricing" and "priced" lose a final e that "price" keeps.
        if word.count > 4, word.hasSuffix("e") { word = String(word.dropLast()) }
        return word
    }
}

/// "Last week", "this month", "yesterday": the calls a question is about.
public enum MemoryTimeFilter {
    public static func range(in query: String, now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        let text = query.lowercased()
        func interval(_ component: Calendar.Component, offset: Int) -> DateInterval? {
            guard let shifted = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: component, for: shifted)
        }
        if text.contains("yesterday") { return interval(.day, offset: -1) }
        if text.contains("today") { return interval(.day, offset: 0) }
        if text.contains("last week") || text.contains("past week") { return interval(.weekOfYear, offset: -1) }
        if text.contains("this week") { return interval(.weekOfYear, offset: 0) }
        if text.contains("last month") || text.contains("past month") { return interval(.month, offset: -1) }
        if text.contains("this month") { return interval(.month, offset: 0) }
        return nil
    }
}
