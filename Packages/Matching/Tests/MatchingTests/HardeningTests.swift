import Core
import Foundation
import Testing
@testable import Matching

// MARK: - Fixtures

private func candidate(
    _ path: String, terms: [String], gitActivity: Date? = nil
) -> ProjectCandidate {
    ProjectCandidate(
        path: URL(filePath: path), name: URL(filePath: path).lastPathComponent,
        hasClaudeMD: false, profileTerms: terms, lastGitActivity: gitActivity)
}

private func transcript(_ text: String) -> Transcript {
    Transcript(
        segments: [TranscriptSegment(speaker: .me, start: 0, end: 5, text: text, confidence: 0.9)],
        language: "en")
}

// MARK: - Prefilter hardening

@Suite struct PrefilterHardeningTests {

    @Test func recentGitActivityOutranksDormantTwin() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = candidate("/p/fresh", terms: ["payments", "api"],
                              gitActivity: now.addingTimeInterval(-3_600))
        let dormant = candidate("/p/dormant", terms: ["payments", "api"],
                                gitActivity: now.addingTimeInterval(-90 * 86_400))
        let ranked = Prefilter.rank(
            candidates: [dormant, fresh],
            transcript: transcript("the payments api needs a retry"),
            calendar: nil, now: now)
        #expect(ranked.first?.candidate.path.path == "/p/fresh")
    }

    @Test func recencyAloneNeverScoresAContentMiss() {
        let now = Date()
        let unrelated = candidate("/p/unrelated", terms: ["gardening"],
                                  gitActivity: now)
        let ranked = Prefilter.rank(
            candidates: [unrelated],
            transcript: transcript("the payments api needs a retry"),
            calendar: nil, now: now)
        #expect(ranked.isEmpty)
    }

    @Test func externalBoostLiftsACandidate() {
        let a = candidate("/p/a", terms: ["payments", "api"])
        let b = candidate("/p/b", terms: ["payments", "api"])
        let ranked = Prefilter.rank(
            candidates: [a, b],
            transcript: transcript("payments api retry"),
            calendar: nil,
            boosts: ["/p/b": 8])
        #expect(ranked.first?.candidate.path.path == "/p/b")
    }

    @Test func closeRaceWidensTheShortlist() {
        // Seven near-identical candidates: a close race must widen past 5.
        let candidates = (0..<7).map {
            candidate("/p/proj\($0)", terms: ["payments", "api", "retry"])
        }
        let ranked = Prefilter.rank(
            candidates: candidates,
            transcript: transcript("payments api retry logic"),
            calendar: nil)
        #expect(ranked.count == 7)
    }

    @Test func dominantWinnerKeepsTheTightShortlist() {
        var candidates = (0..<7).map {
            candidate("/p/noise\($0)", terms: ["payments"])
        }
        candidates.append(candidate(
            "/p/winner", terms: ["payments", "api", "retry", "winner"]))
        let ranked = Prefilter.rank(
            candidates: candidates,
            transcript: transcript(
                "the winner winner payments api retry logic for winner"),
            calendar: CalendarContext(title: "Winner sync", attendees: []))
        #expect(ranked.count == 5)
        #expect(ranked.first?.candidate.path.path == "/p/winner")
    }
}

// MARK: - Escalation gate

@Suite struct EscalationGateTests {

    private func scored(_ path: String, _ score: Double) -> ScoredCandidate {
        ScoredCandidate(candidate: candidate(path, terms: ["x"]), score: score)
    }

    @Test func meetingLinkPinsEvenWithoutCalendarAgreement() {
        let decision = EscalationGate.decide(
            ranked: [scored("/p/acme", 5), scored("/p/other", 4)],
            calendarAgrees: false,
            meetingMappedPath: "/p/acme")
        #expect(decision == .pinned(scored("/p/acme", 5)))
    }

    @Test func meetingLinkToADifferentProjectDoesNotPin() {
        let decision = EscalationGate.decide(
            ranked: [scored("/p/acme", 5), scored("/p/other", 4)],
            calendarAgrees: true,
            meetingMappedPath: "/p/elsewhere")
        #expect(decision == .judge)
    }

    @Test func dominantWinnerWithCalendarPins() {
        let decision = EscalationGate.decide(
            ranked: [scored("/p/acme", 12), scored("/p/other", 3)],
            calendarAgrees: true,
            meetingMappedPath: nil)
        #expect(decision == .pinned(scored("/p/acme", 12)))
    }

    @Test func dominantWinnerWithoutCalendarJudges() {
        let decision = EscalationGate.decide(
            ranked: [scored("/p/acme", 12), scored("/p/other", 3)],
            calendarAgrees: false,
            meetingMappedPath: nil)
        #expect(decision == .judge)
    }

    @Test func closeRaceJudgesDespiteCalendar() {
        let decision = EscalationGate.decide(
            ranked: [scored("/p/acme", 12), scored("/p/other", 9)],
            calendarAgrees: true,
            meetingMappedPath: nil)
        #expect(decision == .judge)
    }

    @Test func soleStrongCandidateWithCalendarPins() {
        #expect(EscalationGate.decide(
            ranked: [scored("/p/acme", 9)],
            calendarAgrees: true, meetingMappedPath: nil)
            == .pinned(scored("/p/acme", 9)))
        #expect(EscalationGate.decide(
            ranked: [scored("/p/acme", 3)],
            calendarAgrees: true, meetingMappedPath: nil) == .judge)
    }

    @Test func emptyShortlistJudges() {
        #expect(EscalationGate.decide(
            ranked: [], calendarAgrees: true, meetingMappedPath: nil) == .judge)
    }

    @Test func calendarAgreementMatchesNameTokens() {
        let acme = candidate("/p/acme-billing", terms: ["x"])
        #expect(EscalationGate.calendarAgrees(
            CalendarContext(title: "Acme billing sync", attendees: []), with: acme))
        #expect(!EscalationGate.calendarAgrees(
            CalendarContext(title: "Weekly standup", attendees: []), with: acme))
        #expect(!EscalationGate.calendarAgrees(nil, with: acme))
    }
}

// MARK: - Embedder (pure parts)

@Suite struct EmbedderTests {

    @Test func samplingIsEvenAndOrderPreserving() {
        let texts = (0..<100).map(String.init)
        let sampled = TranscriptEmbedder.sample(texts, limit: 10)
        #expect(sampled.count == 10)
        #expect(sampled == sampled.sorted { Int($0)! < Int($1)! })
        #expect(Int(sampled.last!)! >= 90)
        #expect(TranscriptEmbedder.sample(["a", "b"], limit: 10) == ["a", "b"])
    }

    @Test func averageAndCosineBehave() {
        #expect(TranscriptEmbedder.average([[1, 3], [3, 5]]) == [2, 4])
        #expect(TranscriptEmbedder.average([]) == nil)
        #expect(TranscriptEmbedder.average([[1], [1, 2]]) == nil)
        #expect(TranscriptEmbedder.cosine([1, 0], [1, 0]) == 1)
        #expect(abs(TranscriptEmbedder.cosine([1, 0], [0, 1])) < 0.0001)
        #expect(TranscriptEmbedder.cosine([1, 0], [1]) == 0)
        #expect(TranscriptEmbedder.cosine([0, 0], [1, 1]) == 0)
    }
}

// MARK: - Git recency profiling

@Test func gitActivityReadsMarkerMtimes() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("matching-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(CandidateEnumerator.lastGitActivity(at: dir) == nil)
    try "ref: refs/heads/main".write(
        to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    let activity = CandidateEnumerator.lastGitActivity(at: dir)
    #expect(activity != nil)
    #expect(abs(activity!.timeIntervalSinceNow) < 60)
}
