import Foundation
import Testing
@testable import Core

@Suite struct CallCoachTests {

    func me(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: .me, start: start, end: end, text: text, confidence: 1)
    }

    func them(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: .them(label: nil), start: start, end: end, text: text, confidence: 1)
    }

    @Test func measuresTalkTimePaceAndQuestions() {
        let stats = CallCoach.stats([
            me(0, 30, Array(repeating: "word", count: 75).joined(separator: " ")),
            them(31, 61, "Sure, let me walk you through how we buy software today."),
            me(62, 72, "What does your timeline look like for this?"),
        ])
        #expect(stats.myTalk == 40)
        #expect(stats.theirTalk == 30)
        #expect(abs((stats.talkShare ?? 0) - 40.0 / 70.0) < 1e-9)
        #expect(stats.myWords == 83)
        #expect(abs((stats.wordsPerMinute ?? 0) - 83.0 * 60 / 40) < 1e-9)
        #expect(stats.questionsAsked == 1)
        #expect(stats.pace == .steady)
    }

    @Test func aMonologueRunsUntilTheyReallySpeak() {
        let stats = CallCoach.stats([
            me(0, 20, "First part of a long explanation about the product"),
            them(20.5, 21, "yeah"),
            me(21.5, 50, "and more about the roadmap and the pricing and so on"),
            them(51, 60, "Okay, how does that work with our SSO setup though?"),
            me(61, 70, "Good question, it works like this"),
        ])
        #expect(stats.longestMonologue == 50)
    }

    @Test func aLongPauseEndsMyTurn() {
        let turns = CallCoach.myTurns([me(0, 10, "one two three"), me(20, 30, "four five six")]).turns
        #expect(turns == [0...10, 20...30])
    }

    @Test func countsFillersAsWholeWords() {
        let stats = CallCoach.stats([
            me(0, 30, "Um, so, you know, the thing is, uh, basically we, um, ship weekly. I mean it."),
            me(31, 40, "Humble umbrella, you knowledge"),
        ])
        #expect(stats.fillerCount == 6)
        #expect(stats.fillers.first == CoachingStats.Filler(phrase: "um", count: 2))
        #expect(stats.fillers.contains(CoachingStats.Filler(phrase: "you know", count: 1)))
    }

    @Test func talkingOverThemCounts() {
        let stats = CallCoach.stats([
            them(0, 10, "So the reason we moved off the old vendor was mostly cost"),
            me(6, 12, "Right, and our pricing fixes exactly that"),
            them(13, 20, "Well the other reason was the support quality"),
            me(19.5, 25, "Got it, yes"),
            me(19.8, 20, "yeah"),
        ])
        // The second line starts half a second before they finish: not a talk-over.
        #expect(stats.talkOvers == 1)
    }

    @Test func noSpeechNoNumbers() {
        let stats = CallCoach.stats([])
        #expect(stats.talkShare == nil)
        #expect(stats.wordsPerMinute == nil)
        #expect(stats.pace == nil)
        #expect(stats.longestMonologue == 0)
    }

    @Test func theCurrentTurnCountsWordsInProgress() {
        let segments = [them(0, 5, "Tell me about your company please"), me(6, 40, "We started in 2019 and...")]
        // Still talking: a partial runs to 70 s.
        #expect(CallCoach.currentTurn(segments, partial: (start: 41, end: 70), now: 71) == 65)
        // Quiet for a while: no turn.
        #expect(CallCoach.currentTurn(segments, partial: nil, now: 60) == 0)
        // They answered: my turn is over.
        let answered = segments + [them(41, 50, "That's great, and how many customers do you have?")]
        #expect(CallCoach.currentTurn(answered, partial: nil, now: 51) == 0)
    }

    @Test func thePromptLineStatesTheNumbers() {
        let stats = CoachingStats(
            myTalk: 600, theirTalk: 400, myWords: 1_500, longestMonologue: 125, questionsAsked: 3,
            fillerCount: 12, fillers: [.init(phrase: "um", count: 8), .init(phrase: "you know", count: 4)], talkOvers: 2)
        #expect(stats.promptLine == "I talked 60% of the time; at about 150 words a minute; my longest uninterrupted stretch was 02:05; I asked 3 questions; filler words: 12 (\"um\" 8, \"you know\" 4); I talked over them 2 times.")
    }
}

@Suite struct CoachingPlaybookTests {

    @Test func builtInsCoachWhereTheUserLeadsTheCall() {
        #expect(Playbook.sales.coaches)
        #expect(Playbook.sales.checklistItems.contains("Budget"))
        #expect(!Playbook.general.coaches)
        #expect(Playbook.general.checklistItems.isEmpty)
    }

    @Test func aCopyKeepsTheDefaultsItInherited() {
        let copy = Playbook.sales.duplicated()
        #expect(copy.coaches)
        #expect(copy.checklistItems == Playbook.sales.checklistItems)
        #expect(copy.lens == Playbook.sales.lens)
    }

    @Test func checklistItemsAreTrimmedAndUnique() {
        var playbook = Playbook.general
        playbook.checklist = [" Budget ", "budget", "", "Timeline"]
        #expect(playbook.checklistItems == ["Budget", "Timeline"])
    }

    @Test func notesTrackCoveredItemsAndOldNotesStillOpen() throws {
        let text = "KEY POINTS:\n- (none)\nDECISIONS:\n- (none)\nACTION ITEMS:\n- (none)\nOPEN QUESTIONS:\n- (none)\nCOVERED:\n- budget.\n- Next step agreed"
        let notes = try #require(LiveNotes.parse(text, coveredUntil: 10))
        #expect(notes.coveredItems(of: ["Budget", "Timeline", "Next step agreed"]) == ["Budget", "Next step agreed"])
        #expect(notes.plainText(withChecklist: true).hasSuffix("COVERED:\n- budget.\n- Next step agreed"))
        #expect(!notes.plainText.contains("COVERED"))

        let old = #"{"keyPoints":["a"],"decisions":[],"actionItems":[],"openQuestions":[],"coveredUntil":5,"updatedAt":0}"#
        let decoded = try JSONDecoder().decode(LiveNotes.self, from: Data(old.utf8))
        #expect(decoded.keyPoints == ["a"])
        #expect(decoded.covered.isEmpty)
    }

    @Test func theChecklistShowsInExportsButCoachingDoesNot() {
        let summary = MeetingSummary(
            title: "Acme demo", tldr: "Good call.",
            coaching: CoachingFeedback(wentWell: ["Clear demo"], tryNext: ["Ask about budget earlier"]),
            checklist: [.init(item: "Budget", covered: true, evidence: "$50k approved"), .init(item: "Timeline", covered: false)])
        let markdown = summary.markdown()
        #expect(markdown.contains("## Checklist\n- [x] Budget: $50k approved\n- [ ] Timeline"))
        #expect(!markdown.contains("Ask about budget earlier"))
        #expect(MeetingSummary(title: "t", tldr: "", coaching: CoachingFeedback(), checklist: []).coaching == nil)
    }
}
