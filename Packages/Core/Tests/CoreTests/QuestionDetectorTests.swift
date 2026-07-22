import Testing
@testable import Core

@Suite struct QuestionDetectorTests {

    @Test func questionMarksAndOpenersDetect() {
        #expect(QuestionDetector.looksLikeQuestion("Does the API support batch export?"))
        #expect(QuestionDetector.looksLikeQuestion("how do I reset my password please"))
        #expect(QuestionDetector.looksLikeQuestion("Can you walk me through pricing"))
    }

    @Test func statementsAndShortFragmentsDoNot() {
        #expect(!QuestionDetector.looksLikeQuestion("We shipped it on Friday."))
        #expect(!QuestionDetector.looksLikeQuestion("ok?"))
        #expect(!QuestionDetector.looksLikeQuestion("whatever happens happens"))
        #expect(!QuestionDetector.looksLikeQuestion(""))
    }

    @Test func promptKindStorageKeysAreStable() {
        #expect(PromptKind.liveAssist.rawValue == "live_assist")
        #expect(PromptKind.vocabulary.rawValue == "vocabulary")
        #expect(PromptKind.filing.rawValue == "filing")
    }
}
