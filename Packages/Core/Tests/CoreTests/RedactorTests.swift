import Testing
@testable import Core

@Suite struct RedactorTests {

    @Test func masksEmailsNumbersAndAmounts() {
        let redacted = Redactor.redact(
            "Reach jane.doe+x@acme.co or +1 (415) 555-0134; budget is $12,500.")
        #expect(!redacted.contains("jane.doe"))
        #expect(!redacted.contains("555"))
        #expect(!redacted.contains("12,500"))
        #expect(redacted.contains("[email]"))
        #expect(redacted.contains("[number]"))
        #expect(redacted.contains("[amount]"))
    }

    @Test func leavesOrdinarySpeechAlone() {
        let text = "We ship on May 3 and the retry count is 5."
        #expect(Redactor.redact(text) == text)
    }

    @Test func versionNumbersSurvive() {
        #expect(Redactor.redact("Upgrade to 2.3.1 today") == "Upgrade to 2.3.1 today")
    }
}
