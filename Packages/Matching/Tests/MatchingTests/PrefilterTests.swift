import Core
import Foundation
import Testing
@testable import Matching

@Test func moduleLinksAndReportsIdentity() {
    #expect(MatchingModule.name == "Matching")
}

@Suite struct PrefilterTests {

    private func candidate(_ name: String, terms: [String]) -> ProjectCandidate {
        ProjectCandidate(
            path: URL(filePath: "/tmp/\(name)"), name: name,
            hasClaudeMD: true, profileTerms: terms)
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(speaker: .me, start: 0, end: 1, text: text, confidence: 0.9)],
            language: "en")
    }

    @Test func tokenizerSplitsCamelCaseAndDropsStopwords() {
        let tokens = Prefilter.tokenize("The CaptureSession and RingBuffer for whisper")
        #expect(tokens.contains("capturesession"))
        #expect(tokens.contains("capture"))
        #expect(tokens.contains("session"))
        #expect(tokens.contains("ringbuffer"))
        #expect(tokens.contains("whisper"))
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("and"))
    }

    @Test func vocabularyOverlapWins() {
        let audio = candidate("saaa", terms: ["whisper", "capture", "transcript", "notch"])
        let webshop = candidate("shopfront", terms: ["checkout", "cart", "stripe", "orders"])
        let ranked = Prefilter.rank(
            candidates: [webshop, audio],
            transcript: transcript("We should trim silence before whisper sees the capture."),
            calendar: nil)
        #expect(ranked.first?.candidate.name == "saaa")
    }

    @Test func spokenProjectNameDominates() {
        let a = candidate("payments", terms: ["stripe", "invoice", "billing"])
        let b = candidate("saaa", terms: ["swift"])
        let ranked = Prefilter.rank(
            candidates: [a, b],
            transcript: transcript("Let's talk about the saaa app."),
            calendar: nil)
        #expect(ranked.first?.candidate.name == "saaa")
    }

    @Test func calendarBoostBreaksTies() {
        let a = candidate("acme-api", terms: ["endpoint", "swift"])
        let b = candidate("beta-api", terms: ["endpoint", "swift"])
        let calendar = CalendarContext(title: "Acme sync", attendees: ["jane@acme.com"])
        let ranked = Prefilter.rank(
            candidates: [a, b],
            transcript: transcript("The endpoint changes ship this week."),
            calendar: calendar)
        #expect(ranked.first?.candidate.name == "acme-api")
        #expect(ranked[0].score > ranked[1].score)
    }

    @Test func zeroOverlapIsExcludedAndLimitHolds() {
        let noise = (0..<10).map { candidate("proj\($0)", terms: ["term\($0)"]) }
        let hit = candidate("saaa", terms: ["whisper"])
        let ranked = Prefilter.rank(
            candidates: noise + [hit],
            transcript: transcript("whisper models are large"),
            calendar: nil, limit: 5)
        #expect(ranked.count == 1)
        #expect(ranked.first?.candidate.name == "saaa")
    }

    @Test func emptyTranscriptRanksNothing() {
        let ranked = Prefilter.rank(
            candidates: [candidate("saaa", terms: ["whisper"])],
            transcript: transcript(""), calendar: nil)
        #expect(ranked.isEmpty)
    }
}

@Suite struct CandidateEnumeratorTests {

    /// Builds a fake ~/.claude/projects store + real project dirs.
    private func makeFixture() throws -> (claudeRoot: URL, projectA: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enum-test-\(UUID().uuidString)", isDirectory: true)
        let projectA = root.appendingPathComponent("code/alpha", isDirectory: true)
        let projectB = root.appendingPathComponent("code/beta", isDirectory: true)
        let store = root.appendingPathComponent(".claude/projects", isDirectory: true)
        for dir in [projectA, projectB,
                    store.appendingPathComponent("-code-alpha"),
                    store.appendingPathComponent("-code-beta"),
                    store.appendingPathComponent("-code-gone")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try #"{"cwd":"\#(projectA.path)","type":"user"}"#.write(
            to: store.appendingPathComponent("-code-alpha/s1.jsonl"),
            atomically: true, encoding: .utf8)
        try #"{"cwd":"\#(projectB.path)","type":"user"}"#.write(
            to: store.appendingPathComponent("-code-beta/s1.jsonl"),
            atomically: true, encoding: .utf8)
        try #"{"cwd":"\#(root.path)/code/deleted-project"}"#.write(
            to: store.appendingPathComponent("-code-gone/s1.jsonl"),
            atomically: true, encoding: .utf8)
        try "# Alpha\nAudio capture for calls\n".write(
            to: projectA.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        return (root.appendingPathComponent(".claude"), projectA)
    }

    @Test func enumeratesRealProjectsSkippingDeleted() throws {
        let (claudeRoot, projectA) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: claudeRoot.deletingLastPathComponent()) }

        let candidates = CandidateEnumerator(claudeRoot: claudeRoot).enumerate()
        #expect(candidates.count == 2)
        let alpha = try #require(candidates.first { $0.name == "alpha" })
        #expect(alpha.path.standardizedFileURL.path == projectA.standardizedFileURL.path)
        #expect(alpha.hasClaudeMD)
        #expect(alpha.profileTerms.contains("Alpha"))
        let beta = try #require(candidates.first { $0.name == "beta" })
        #expect(!beta.hasClaudeMD)
    }

    @Test func missingStoreYieldsEmpty() {
        let candidates = CandidateEnumerator(
            claudeRoot: URL(filePath: "/nonexistent-\(UUID().uuidString)")).enumerate()
        #expect(candidates.isEmpty)
    }
}
