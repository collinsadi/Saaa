import Foundation
import Testing
@testable import Core

@Suite struct CallMemoryTests {

    static let now = Date(timeIntervalSince1970: 1_791_700_000)  // Oct 2026

    static func line(_ speaker: Speaker, _ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: start + 4, text: text, confidence: 1)
    }

    static let acme = MemorySource(
        id: UUID(), title: "Acme renewal", startedAt: now.addingTimeInterval(-3 * 86_400), playbookName: "Sales",
        participants: "Dana Lee (Acme, CFO)",
        summary: ["TL;DR: Acme renews if SSO ships by May.", "Action item: Send the SSO timeline (Me, due Friday)"],
        segments: [
            line(.them(label: nil), 0, "Thanks for making time today."),
            line(.me, 5, "Happy to. How is the rollout going?"),
            line(.them(label: nil), 10, "Mostly fine, but the per-seat pricing hurts at our size."),
            line(.me, 15, "We can look at volume prices for teams over 200 seats."),
            line(.them(label: nil), 20, "That would help. Also security wants SAML before renewal."),
        ])

    static let globex = MemorySource(
        id: UUID(), title: "Globex intro", startedAt: now.addingTimeInterval(-40 * 86_400), playbookName: "Sales",
        participants: "Hank Scorpio",
        summary: ["TL;DR: Globex wants a pilot for the support team."],
        segments: [line(.them(label: nil), 0, "We need a pilot for our support team first."), line(.me, 5, "A two week pilot works.")])

    static let standup = MemorySource(
        id: UUID(), title: "Team standup", startedAt: now.addingTimeInterval(-1 * 86_400), playbookName: "Standup",
        summary: ["TL;DR: Release slips a day."],
        segments: [line(.me, 0, "I'm finishing the importer today.")])

    let index = MemoryIndex(sources: [acme, globex, standup])

    @Test func findsTheMomentAboutPricingInTheRightCall() throws {
        let excerpts = index.search("What did Acme say about pricing?", now: Self.now)
        let first = try #require(excerpts.first { $0.chunk.kind == .transcript })
        #expect(first.sessionID == Self.acme.id)
        #expect(first.chunk.text.contains("per-seat pricing"))
        #expect(!excerpts.contains { $0.sessionID == Self.standup.id })
    }

    @Test func stemmingMeetsDifferentFormsOfAWord() {
        #expect(MemoryIndex.stem("pricing") == MemoryIndex.stem("prices"))
        #expect(MemoryIndex.stem("priced") == MemoryIndex.stem("price"))
        #expect(MemoryIndex.stem("renewing") == "renew")
        #expect(MemoryIndex.stem("status") == "status")
        #expect(MemoryIndex.tokens("The SSO and the SAML") == ["sso", "saml"])
    }

    @Test func titlesAndPeopleCountInEveryChunk() {
        let excerpts = index.search("Hank", now: Self.now)
        #expect(!excerpts.isEmpty)
        #expect(excerpts.allSatisfy { $0.sessionID == Self.globex.id })
    }

    @Test func timePhrasesNarrowTheCalls() {
        let lastWeek = index.search("What happened this week?", now: Self.now)
        #expect(!lastWeek.isEmpty)
        #expect(!lastWeek.contains { $0.sessionID == Self.globex.id })
        #expect(lastWeek.allSatisfy { $0.chunk.kind == .summary })
    }

    @Test func excerptsReadOldestFirstAndRespectTheBudget() {
        let excerpts = index.search("pilot pricing renewal", characterBudget: 400, now: Self.now)
        #expect(excerpts.reduce(0) { $0 + $1.chunk.text.count } <= 400)
        #expect(excerpts.map(\.startedAt) == excerpts.map(\.startedAt).sorted())
    }

    @Test func longTranscriptsBecomeOverlappingChunks() {
        let segments = (0..<20).map { Self.line(.them(label: nil), Double($0) * 5, "Line number \($0) of a long talk about many things") }
        let pieces = MemoryIndex.pieces(of: MemorySource(id: UUID(), title: "Long", startedAt: Self.now, segments: segments))
            .filter { $0.kind == .transcript }
        #expect(pieces.count > 2)
        #expect(pieces.allSatisfy { $0.text.split(separator: "\n").count <= MemoryIndex.chunkLines })
        // The last lines of one chunk open the next.
        let firstLast = pieces[0].text.split(separator: "\n").last
        #expect(pieces[1].text.split(separator: "\n").contains { $0 == firstLast })
        #expect(pieces[1].callTime == segments[MemoryIndex.chunkLines - MemoryIndex.overlapLines].start)
    }

    @Test func anEmptyLibraryFindsNothing() {
        let empty = MemoryIndex(sources: [])
        #expect(empty.isEmpty)
        #expect(empty.search("anything at all").isEmpty)
    }

    @Test func timeFilterUnderstandsCommonPhrases() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let range = try #require(MemoryTimeFilter.range(in: "What did I promise last month?", now: Self.now, calendar: calendar))
        #expect(range.contains(Self.now.addingTimeInterval(-31 * 86_400)))
        #expect(!range.contains(Self.now))
        #expect(MemoryTimeFilter.range(in: "What about pricing?", now: Self.now) == nil)
    }
}
