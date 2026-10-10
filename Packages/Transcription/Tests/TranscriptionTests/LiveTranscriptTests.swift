import Core
import Foundation
import Testing
@testable import Transcription

@Suite struct LiveTranscriptTests {

    @Test func commitsInTimeOrderEvenWhenLanesFinalizeLate() {
        var transcript = LiveTranscript()
        transcript.commit(.them, start: 2.0, end: 3.5, text: "What's the budget?")
        transcript.commit(.me, start: 4.0, end: 5.0, text: "Around fifty thousand.")
        // The Them lane finalizes an earlier phrase after Me's.
        transcript.commit(.them, start: 0.5, end: 1.8, text: "Thanks for joining.")
        #expect(transcript.entries.map(\.segment.start) == [0.5, 2.0, 4.0])
        #expect(transcript.transcript.attributedText == """
        Them: Thanks for joining.
        Them: What's the budget?
        Me: Around fifty thousand.
        """)
    }

    @Test func partialsReplaceAndFinalsClearThem() {
        var transcript = LiveTranscript()
        transcript.setPartial(.them, start: 1, end: 1.4, text: "what is")
        transcript.setPartial(.them, start: 1, end: 2.0, text: "what is the")
        #expect(transcript.lines.count == 1)
        #expect(transcript.lines.first?.text == "what is the")
        #expect(transcript.lines.first?.isFinal == false)
        transcript.commit(.them, start: 1, end: 2.4, text: "What is the timeline?")
        #expect(transcript.partials[.them] == nil)
        #expect(transcript.lines.map(\.isFinal) == [true])
    }

    @Test func partialBeyondTheFinalSurvives() {
        var transcript = LiveTranscript()
        transcript.setPartial(.me, start: 3, end: 6, text: "and then we")
        transcript.commit(.me, start: 1, end: 2.5, text: "Sounds good.")
        #expect(transcript.partials[.me]?.text == "and then we")
    }

    @Test func echoOnTheMicIsDroppedWhenThemAlreadyHasIt() {
        var transcript = LiveTranscript()
        transcript.commit(.them, start: 10, end: 13, text: "We need the contract signed by Friday.")
        let outcome = transcript.commit(.me, start: 10.4, end: 13.1, text: "we need the contract signed by friday")
        #expect(outcome.droppedAsEcho)
        #expect(transcript.entries.count == 1)
        #expect(transcript.echoCount == 1)
    }

    @Test func echoCommittedFirstIsRetractedByThem() {
        var transcript = LiveTranscript()
        transcript.commit(.me, start: 20.2, end: 23, text: "Can you share the deck after the call")
        transcript.commit(.me, start: 30, end: 31, text: "Sure, will do.")
        let outcome = transcript.commit(.them, start: 20, end: 23, text: "Can you share the deck after the call?")
        #expect(outcome.removedEchoes == 1)
        #expect(transcript.entries.map(\.lane) == [.them, .me])
    }

    @Test func realRepliesAreNotEchoes() {
        var transcript = LiveTranscript()
        transcript.commit(.them, start: 5, end: 7, text: "Do you support single sign-on?")
        let outcome = transcript.commit(.me, start: 7.5, end: 9, text: "Yes, we support single sign-on with Okta.")
        // Shares words but is a different, longer utterance.
        #expect(!outcome.droppedAsEcho || transcript.entries.count == 1)
        let short = transcript.commit(.me, start: 9.2, end: 9.5, text: "Yeah.")
        #expect(!short.droppedAsEcho)
    }

    @Test func settledPrefixIsStableAndTimeBounded() {
        var transcript = LiveTranscript()
        for index in 0..<10 {
            transcript.commit(index.isMultiple(of: 2) ? .them : .me,
                              start: Double(index) * 3, end: Double(index) * 3 + 2, text: "line \(index) words here")
        }
        let settled = transcript.settled(before: 15)
        #expect(settled.count == 5)
        #expect(transcript.unsettled(from: 15).count == 5)
        #expect(transcript.settled(before: 1_000).count == 10)
    }

    @Test func talkTimeSumsCommittedSpans() {
        var transcript = LiveTranscript()
        transcript.commit(.me, start: 0, end: 4, text: "one two three")
        transcript.commit(.them, start: 5, end: 6, text: "four five six")
        let time = transcript.talkTime
        #expect(time.me == 4)
        #expect(time.them == 1)
    }

    @Test func emptyFinalsAreIgnoredButClearPartials() {
        var transcript = LiveTranscript()
        transcript.setPartial(.them, start: 0, end: 1, text: "uh")
        let outcome = transcript.commit(.them, start: 0, end: 1.2, text: "   ")
        #expect(outcome.added == nil)
        #expect(transcript.entries.isEmpty)
        #expect(transcript.partials.isEmpty)
    }

    @Test func eventsApplyThroughTheTranscriberEnum() {
        var transcript = LiveTranscript()
        transcript.apply(.partial(.them, start: 0, end: 1, text: "hel"))
        transcript.apply(.final(.them, start: 0, end: 1.2, text: "Hello there."))
        transcript.apply(.laneFailed(.me, "x"))
        #expect(transcript.plainText == "Them: Hello there.")
    }
}

@Suite struct TextSimilarityTests {

    @Test func nearDuplicatesAndNot() {
        #expect(TextSimilarity.isNearDuplicate("We ship on Friday, right?", "we ship on friday right"))
        #expect(TextSimilarity.isNearDuplicate("the numbers look great this quarter", "numbers look great this quarter"))
        #expect(!TextSimilarity.isNearDuplicate("okay", "okay"))
        #expect(!TextSimilarity.isNearDuplicate("What is the price?", "The price is ten dollars per seat per month."))
        #expect(!TextSimilarity.isNearDuplicate("line 1 words here", "line 0 words here"))
        #expect(TextSimilarity.words("Don't stop—now!") == ["don't", "stop", "now"])
    }
}
