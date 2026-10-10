import Testing
@testable import Core

@Suite struct QuestionDetectorTests {

    @Test func questionMarksAndOpenersDetect() {
        #expect(QuestionDetector.looksLikeQuestion("Does the API support batch export?"))
        #expect(QuestionDetector.looksLikeQuestion("how do I reset my password please"))
        #expect(QuestionDetector.looksLikeQuestion("Can you walk me through pricing"))
        #expect(QuestionDetector.looksLikeQuestion("I was wondering how you handle SSO"))
    }

    @Test func statementsFillersAndShortFragmentsDoNot() {
        #expect(!QuestionDetector.looksLikeQuestion("We shipped it on Friday."))
        #expect(!QuestionDetector.looksLikeQuestion("ok?"))
        #expect(!QuestionDetector.looksLikeQuestion("whatever happens happens"))
        #expect(!QuestionDetector.looksLikeQuestion("That works, right?"))
        #expect(!QuestionDetector.looksLikeQuestion(""))
    }

    @Test func extractsTheQuestionFromALongerPhrase() {
        let text = "We looked at three vendors last quarter. How does your pricing work for teams? Just curious."
        #expect(QuestionDetector.extractQuestion(text) == "How does your pricing work for teams?")
        #expect(QuestionDetector.extractQuestion("Thanks, that's all for today.") == nil)
    }
}
