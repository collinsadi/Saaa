import Foundation

/// How the user spoke on a call, measured on the Mac from the transcript.
/// No model is involved and nothing leaves the Mac.
public struct CoachingStats: Sendable, Equatable, Codable {

    public struct Filler: Sendable, Equatable, Codable, Hashable {
        public var phrase: String
        public var count: Int

        public init(phrase: String, count: Int) {
            self.phrase = phrase
            self.count = count
        }
    }

    public enum Pace: String, Sendable, Equatable {
        case slow, steady, fast

        public var label: String {
            switch self {
            case .slow: "Slow"
            case .steady: "Steady"
            case .fast: "Fast"
            }
        }
    }

    /// Seconds each side spent speaking.
    public var myTalk: TimeInterval
    public var theirTalk: TimeInterval
    public var myWords: Int
    /// The longest stretch I talked without the other side getting a word in.
    public var longestMonologue: TimeInterval
    public var questionsAsked: Int
    public var fillerCount: Int
    /// Most used first.
    public var fillers: [Filler]
    /// Times I started talking while they were mid-sentence.
    public var talkOvers: Int

    public init(
        myTalk: TimeInterval = 0, theirTalk: TimeInterval = 0, myWords: Int = 0, longestMonologue: TimeInterval = 0,
        questionsAsked: Int = 0, fillerCount: Int = 0, fillers: [Filler] = [], talkOvers: Int = 0
    ) {
        self.myTalk = myTalk
        self.theirTalk = theirTalk
        self.myWords = myWords
        self.longestMonologue = longestMonologue
        self.questionsAsked = questionsAsked
        self.fillerCount = fillerCount
        self.fillers = fillers
        self.talkOvers = talkOvers
    }

    /// My share of the talking, 0...1; nil before anyone spoke.
    public var talkShare: Double? {
        let total = myTalk + theirTalk
        return total > 0 ? myTalk / total : nil
    }

    /// Words a minute while I spoke; nil until there's enough speech to say.
    public var wordsPerMinute: Double? {
        myTalk >= CallCoach.minimumTalk ? Double(myWords) / (myTalk / 60) : nil
    }

    public var fillersPerMinute: Double? {
        myTalk >= CallCoach.minimumTalk ? Double(fillerCount) / (myTalk / 60) : nil
    }

    public var pace: Pace? {
        guard let wordsPerMinute else { return nil }
        if wordsPerMinute < CallCoach.slowPace { return .slow }
        if wordsPerMinute > CallCoach.fastPace { return .fast }
        return .steady
    }

    /// One line for the summary prompt, so feedback rests on real numbers.
    public var promptLine: String {
        var parts: [String] = []
        if let talkShare { parts.append("I talked \(Int((talkShare * 100).rounded()))% of the time") }
        if let wordsPerMinute { parts.append("at about \(Int(wordsPerMinute.rounded())) words a minute") }
        parts.append("my longest uninterrupted stretch was \(CallTime.stamp(longestMonologue))")
        parts.append(questionsAsked == 1 ? "I asked 1 question" : "I asked \(questionsAsked) questions")
        if fillerCount > 0 {
            let top = fillers.prefix(3).map { "\"\($0.phrase)\" \($0.count)" }.joined(separator: ", ")
            parts.append("filler words: \(fillerCount) (\(top))")
        }
        if talkOvers > 0 { parts.append(talkOvers == 1 ? "I talked over them once" : "I talked over them \(talkOvers) times") }
        return parts.joined(separator: "; ") + "."
    }
}

/// Speaking stats and the live "you've been talking a while" nudge, from
/// transcript segments alone.
public enum CallCoach {

    /// A gap shorter than this keeps my turn going.
    public static let turnGap: TimeInterval = 2.5
    /// Their lines shorter than this ("yeah", "right") don't end my turn.
    public static let backchannelWords = 3
    /// The live nudge shows once my turn runs this long.
    public static let monologueNudge: TimeInterval = 90
    /// Below this much speech, pace isn't worth stating.
    public static let minimumTalk: TimeInterval = 20
    public static let slowPace: Double = 110
    public static let fastPace: Double = 180
    /// I started at least this long before they finished: a talk-over.
    public static let talkOverOverlap: TimeInterval = 1

    /// Spoken fillers, counted as whole words. "Like" and "so" are left out:
    /// they're usually real words.
    public static let fillerPhrases = ["um", "uh", "erm", "uhm", "you know", "i mean", "basically", "literally"]

    public static func stats(_ segments: [TranscriptSegment]) -> CoachingStats {
        let ordered = segments.sorted { $0.start < $1.start }
        var stats = CoachingStats()
        var fillerTotals: [String: Int] = [:]
        for segment in ordered {
            let span = max(0, segment.end - segment.start)
            switch segment.speaker {
            case .me:
                stats.myTalk += span
                stats.myWords += wordCount(segment.text)
                if QuestionDetector.extractQuestion(segment.text) != nil { stats.questionsAsked += 1 }
                for (phrase, count) in fillers(in: segment.text) { fillerTotals[phrase, default: 0] += count }
            case .them:
                stats.theirTalk += span
            }
        }
        stats.longestMonologue = myTurns(ordered).turns.map { $0.upperBound - $0.lowerBound }.max() ?? 0
        stats.fillers = fillerTotals.map { CoachingStats.Filler(phrase: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.phrase < $1.phrase }
        stats.fillerCount = fillerTotals.values.reduce(0, +)
        stats.talkOvers = talkOvers(ordered)
        return stats
    }

    /// How long my current turn has run at `now`, counting words still in
    /// progress; zero when I'm not talking.
    public static func currentTurn(
        _ segments: [TranscriptSegment], partial: (start: TimeInterval, end: TimeInterval)?, now: TimeInterval
    ) -> TimeInterval {
        var all = segments
        if let partial {
            all.append(TranscriptSegment(speaker: .me, start: partial.start, end: max(partial.end, partial.start), text: "…", confidence: 1))
        }
        let ordered = all.sorted { $0.start < $1.start }
        guard let open = myTurns(ordered).open, now - open.upperBound <= turnGap + 1 else { return 0 }
        return max(0, now - open.lowerBound)
    }

    /// My turns, and the one still open at the end, if any.
    static func myTurns(_ ordered: [TranscriptSegment]) -> (turns: [ClosedRange<TimeInterval>], open: ClosedRange<TimeInterval>?) {
        var turns: [ClosedRange<TimeInterval>] = []
        var current: ClosedRange<TimeInterval>?
        for segment in ordered {
            switch segment.speaker {
            case .me:
                let end = max(segment.end, segment.start)
                if let run = current, segment.start - run.upperBound <= turnGap {
                    current = run.lowerBound...max(run.upperBound, end)
                } else {
                    if let run = current { turns.append(run) }
                    current = segment.start...end
                }
            case .them:
                if let run = current, segment.start >= run.lowerBound, wordCount(segment.text) >= backchannelWords {
                    turns.append(run)
                    current = nil
                }
            }
        }
        if let current { turns.append(current) }
        return (turns, current)
    }

    /// My lines that start while a real line of theirs still has a second or more to go.
    static func talkOvers(_ ordered: [TranscriptSegment]) -> Int {
        var theirLatestEnd: TimeInterval = -.infinity
        var count = 0
        for segment in ordered {
            switch segment.speaker {
            case .them:
                if wordCount(segment.text) >= backchannelWords { theirLatestEnd = max(theirLatestEnd, segment.end) }
            case .me:
                if wordCount(segment.text) >= backchannelWords, theirLatestEnd - segment.start >= talkOverOverlap { count += 1 }
            }
        }
        return count
    }

    static func fillers(in text: String) -> [String: Int] {
        let words = text.lowercased()
            .split { !$0.isLetter && $0 != "'" }
            .map(String.init)
        var counts: [String: Int] = [:]
        for phrase in fillerPhrases {
            let parts = phrase.split(separator: " ").map(String.init)
            guard words.count >= parts.count else { continue }
            var index = 0
            while index <= words.count - parts.count {
                if Array(words[index..<(index + parts.count)]) == parts {
                    counts[phrase, default: 0] += 1
                    index += parts.count
                } else {
                    index += 1
                }
            }
        }
        return counts
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
