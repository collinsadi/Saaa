import AnthropicKit
import Core
import Foundation
import Testing
import Transcription
@testable import Copilot

@MainActor
@Suite struct EarlyAnswerTests {

    final class Box {
        var transcript = makeTranscript(lines: 6)
        var now: TimeInterval = 40
    }

    func makeEngine(_ claude: MockClaude, playbook: Playbook = .sales, box: Box) -> CopilotEngine {
        let defaults = UserDefaults(suiteName: "saaa.early.\(UUID().uuidString)")!
        return CopilotEngine(
            playbook: playbook, context: SessionContext(), service: claude, defaults: defaults,
            transcript: { box.transcript }, callTime: { box.now })
    }

    @Test func aQuestionMarkStartsTheAnswerBeforeTheLineIsFinal() async {
        let claude = MockClaude()
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.handlePartial("How does pricing work for a team of forty?")
        #expect(engine.isStreaming)
        await waitUntil { !engine.isStreaming }
        var transcript = box.transcript
        let final = transcript.commit(.them, start: 35, end: 38, text: "How does pricing work for a team of forty?")
        engine.handleCommitted(final.added!)
        #expect(claude.requests.count == 1)
        #expect(engine.thread.count == 1)
        #expect(engine.thread.first?.kind == .suggestion)
        #expect(engine.pendingQuestion == nil)
    }

    @Test func aPauseStartsItWhenThereIsNoQuestionMark() async {
        let claude = MockClaude()
        let engine = makeEngine(claude, box: Box())
        engine.handlePartial("how does the pricing work for larger teams")
        #expect(!engine.isStreaming)
        await waitUntil { !engine.thread.isEmpty }
        #expect(engine.thread.first?.prompt == "how does the pricing work for larger teams")
    }

    @Test func newWordsResetThePause() async {
        let claude = MockClaude()
        let engine = makeEngine(claude, box: Box())
        engine.handlePartial("how does the pricing work for larger")
        try? await Task.sleep(for: .milliseconds(300))
        engine.handlePartial("how does the pricing work for larger teams")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(engine.thread.isEmpty)
        await waitUntil { !engine.thread.isEmpty }
        #expect(engine.thread.count == 1)
        #expect(engine.thread.first?.prompt == "how does the pricing work for larger teams")
    }

    @Test func aDifferentFinalQuestionReplacesTheEarlyAnswer() async {
        let claude = MockClaude()
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.handlePartial("Can you send the security review?")
        await waitUntil { !engine.isStreaming && !engine.thread.isEmpty }
        let earlyID = engine.thread.first?.id
        var transcript = box.transcript
        let question = "Can you send the security review and the SOC 2 report before our board meeting?"
        engine.handleCommitted(transcript.commit(.them, start: 35, end: 40, text: question).added!)
        await waitUntil { !engine.isStreaming }
        #expect(claude.requests.count == 2)
        #expect(engine.thread.count == 1)
        #expect(engine.thread.first?.id != earlyID)
        #expect(engine.thread.first?.prompt == question)
    }

    @Test func anEarlyAnswerCutOffByAnotherActionLeavesTheQuestionAsAChip() async {
        let claude = MockClaude(reply: String(repeating: "word ", count: 60), chunkDelay: .milliseconds(20))
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.handlePartial("How does pricing work for a team of forty?")
        engine.ask("What's their budget?")
        var transcript = box.transcript
        let question = "How does pricing work for a team of forty?"
        engine.handleCommitted(transcript.commit(.them, start: 35, end: 38, text: question).added!)
        #expect(engine.pendingQuestion?.text == question)
        #expect(engine.thread.count == 1)
        #expect(engine.latest?.kind == .ask)
        engine.cancel()
    }

    @Test func statementsAndAutoSuggestOffNeverAnswerEarly() async {
        let claude = MockClaude()
        let general = makeEngine(claude, playbook: .general, box: Box())
        general.handlePartial("How does pricing work for a team of forty?")
        let sales = makeEngine(claude, box: Box())
        sales.handlePartial("We should send the deck on Friday.")
        try? await Task.sleep(for: .milliseconds(800))
        #expect(general.thread.isEmpty)
        #expect(sales.thread.isEmpty)
        #expect(claude.requests.isEmpty)
    }

    @Test func sameQuestionToleratesSmallChanges() {
        #expect(CopilotEngine.sameQuestion("What's your budget for this?", "what's your budget for this quarter"))
        #expect(CopilotEngine.sameQuestion("How does pricing work", "How does pricing work?"))
        #expect(!CopilotEngine.sameQuestion(
            "Can you send the security review?",
            "Can you send the security review and the SOC 2 report before our board meeting?"))
    }
}
