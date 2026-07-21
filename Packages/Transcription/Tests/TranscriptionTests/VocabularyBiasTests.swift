import Testing
@testable import Transcription

@Suite struct VocabularyBiasTests {

    @Test func buildsProseStylePrompt() {
        let prompt = VocabularyBias.initialPrompt(terms: ["Saaa", "SwiftUI", "Acme Corp"])
        #expect(prompt == "This call may mention: Saaa, SwiftUI, Acme Corp.")
    }

    @Test func dedupesCaseInsensitivelyPreservingOrder() {
        let prompt = VocabularyBias.initialPrompt(terms: ["Kafka", "kafka", "KAFKA", "gRPC"])
        #expect(prompt == "This call may mention: Kafka, gRPC.")
    }

    @Test func skipsBlankTerms() {
        let prompt = VocabularyBias.initialPrompt(terms: ["  ", "", "\n", "Redis"])
        #expect(prompt == "This call may mention: Redis.")
    }

    @Test func returnsNilForNothing() {
        #expect(VocabularyBias.initialPrompt(terms: []) == nil)
        #expect(VocabularyBias.initialPrompt(terms: ["", "  "]) == nil)
    }

    @Test func capsAtTermBoundary() {
        let terms = (1...200).map { "Term\($0)" }
        let prompt = VocabularyBias.initialPrompt(terms: terms, maxLength: 100)
        let unwrapped = try! #require(prompt)
        #expect(unwrapped.count <= 100)
        #expect(unwrapped.hasSuffix("."))
        // No truncated term: every listed term must be complete.
        let body = unwrapped
            .replacingOccurrences(of: "This call may mention: ", with: "")
            .dropLast()
        for term in body.split(separator: ", ") {
            #expect(term.hasPrefix("Term"))
            #expect(Int(term.dropFirst(4)) != nil)
        }
    }
}
