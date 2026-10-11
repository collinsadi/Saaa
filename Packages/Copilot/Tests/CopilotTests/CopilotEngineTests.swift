import AnthropicKit
import Core
import Foundation
import Testing
import Transcription
@testable import Copilot

@MainActor
@Suite struct CopilotEngineTests {

    final class Box {
        var transcript = makeTranscript(lines: 6)
        var now: TimeInterval = 40
    }

    func makeEngine(_ claude: MockClaude, playbook: Playbook = .sales, box: Box) -> CopilotEngine {
        let defaults = UserDefaults(suiteName: "saaa.copilot.\(UUID().uuidString)")!
        return CopilotEngine(
            playbook: playbook, context: SessionContext(title: "Acme"), service: claude, defaults: defaults,
            transcript: { box.transcript }, callTime: { box.now })
    }

    @Test func quickActionStreamsIntoTheThread() async {
        let claude = MockClaude(reply: "We can start the pilot next week.")
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.run(StandardActions.whatToSay)
        #expect(engine.isStreaming)
        await waitUntil { !engine.isStreaming }
        #expect(engine.latest?.title == "What to say")
        #expect(engine.latest?.response == "We can start the pilot next week.")
        #expect(engine.latest?.firstTokenSeconds == 0.7)
        #expect(engine.ledger.totalRequests == 1)
        #expect(claude.requests.first?.model == "claude-haiku-5-5")
    }

    @Test func autoSuggestAnswersDetectedQuestionsWithCooldown() async {
        let claude = MockClaude()
        let box = Box()
        let engine = makeEngine(claude, box: box)
        #expect(engine.autoSuggestEnabled)  // Sales default
        var transcript = box.transcript
        let outcome = transcript.commit(.them, start: 35, end: 38, text: "How does pricing work for a team of forty?")
        box.transcript = transcript
        engine.handleCommitted(outcome.added!)
        await waitUntil { !engine.isStreaming }
        #expect(engine.thread.count == 1)
        #expect(engine.thread.first?.kind == .suggestion)
        #expect(engine.thread.first?.prompt == "How does pricing work for a team of forty?")
        // A second question inside the cooldown waits as a chip.
        box.now = 45
        let second = transcript.commit(.them, start: 44, end: 46, text: "And is there an annual discount?")
        engine.handleCommitted(second.added!)
        #expect(engine.pendingQuestion?.text == "And is there an annual discount?")
        #expect(engine.thread.count == 1)
        engine.answerPending()
        await waitUntil { !engine.isStreaming }
        #expect(engine.thread.count == 2)
        #expect(engine.pendingQuestion == nil)
    }

    @Test func withoutAutoSuggestQuestionsOnlyBecomeChips() {
        let claude = MockClaude()
        let box = Box()
        let engine = makeEngine(claude, playbook: .general, box: box)
        #expect(!engine.autoSuggestEnabled)
        var transcript = box.transcript
        let outcome = transcript.commit(.them, start: 35, end: 38, text: "What's your timeline for the rollout?")
        engine.handleCommitted(outcome.added!)
        #expect(engine.pendingQuestion != nil)
        #expect(claude.requests.isEmpty)
        // Statements and my own lines never trigger.
        engine.dismissPending()
        let mine = transcript.commit(.me, start: 39, end: 40, text: "What do you think about Friday?")
        engine.handleCommitted(mine.added!)
        #expect(engine.pendingQuestion == nil)
    }

    @Test func answerActionTakesThePendingQuestionAsFocus() async throws {
        let claude = MockClaude()
        let box = Box()
        let engine = makeEngine(claude, playbook: .general, box: box)
        var transcript = box.transcript
        engine.handleCommitted(transcript.commit(.them, start: 35, end: 38, text: "Can you send the security review?").added!)
        engine.run(StandardActions.answer)
        await waitUntil { !engine.isStreaming }
        let tail = text(of: try #require(claude.requests.first?.messages.first?.content.last))
        #expect(tail.contains("The question they just asked: \"Can you send the security review?\""))
    }

    @Test func newActionCancelsTheOneInFlight() async {
        let claude = MockClaude(reply: String(repeating: "word ", count: 80), chunkDelay: .milliseconds(20))
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.run(StandardActions.catchUp)
        try? await Task.sleep(for: .milliseconds(70))
        engine.ask("What's their budget?")
        await waitUntil(timeout: .seconds(5)) { !engine.isStreaming }
        #expect(engine.latest?.kind == .ask)
        #expect(engine.thread.count <= 2)
        #expect(engine.thread.allSatisfy { !$0.response.isEmpty })
    }

    @Test func failuresAreQuietAndLocal() async {
        let claude = MockClaude(failure: .overloaded)
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.run(StandardActions.answer)
        await waitUntil { !engine.isStreaming }
        #expect(engine.latest?.failure == AnthropicError.overloaded.userMessage)
        #expect(engine.notice == AnthropicError.overloaded.userMessage)
    }

    @Test func refinementReworksAPreviousAnswer() async throws {
        let claude = MockClaude(reply: "Long answer here.")
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.run(StandardActions.answer)
        await waitUntil { !engine.isStreaming }
        let first = try #require(engine.latest)
        engine.refine(first.id, .moreDetail)
        await waitUntil { !engine.isStreaming }
        #expect(engine.thread.count == 2)
        #expect(engine.latest?.title == "Answer · more detail")
        let tail = text(of: try #require(claude.requests.last?.messages.first?.content.last))
        #expect(tail.contains("Long answer here."))
    }

    @Test func notesRefreshParsesAndRecordsUsage() async {
        let claude = MockClaude(reply: "KEY POINTS:\n- Budget is 50k\nDECISIONS:\n- (none)\nACTION ITEMS:\n- Send deck (Me)\nOPEN QUESTIONS:\n- Who signs?")
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.refreshNotes()
        await waitUntil { !engine.isUpdatingNotes }
        #expect(engine.notes?.keyPoints == ["Budget is 50k"])
        #expect(engine.notes?.actionItems == ["Send deck (Me)"])
        #expect(engine.ledger.records.first?.role == "notes")
    }

    @Test func notesCadenceNeedsTimeAndNewWords() async {
        let claude = MockClaude(reply: "KEY POINTS:\n- a\nDECISIONS:\n- (none)\nACTION ITEMS:\n- (none)\nOPEN QUESTIONS:\n- (none)")
        let box = Box()
        box.transcript = makeTranscript(lines: 20)
        box.now = 100
        let engine = makeEngine(claude, box: box)
        engine.tick()
        await waitUntil { !engine.isUpdatingNotes }
        #expect(claude.requests.count == 1)
        box.now = 120
        engine.tick()  // too soon
        #expect(claude.requests.count == 1)
    }

    @Test func finishStopsEverythingAndReturnsTheThread() async {
        let claude = MockClaude(reply: String(repeating: "x ", count: 100), chunkDelay: .milliseconds(30))
        let box = Box()
        let engine = makeEngine(claude, box: box)
        engine.run(StandardActions.answer)
        try? await Task.sleep(for: .milliseconds(80))
        let sealed = engine.finish()
        #expect(!engine.isStreaming)
        #expect(sealed.thread.count <= 1)
        engine.ask("anything")
        #expect(claude.requests.count == 1)
    }
}

@Suite struct SummaryServiceTests {

    @Test func summarizesAndPricesTheRequest() async throws {
        let claude = MockClaude(structuredValue: [
            "title": "Weekly sync", "tldr": "Shipping Friday.", "key_points": [], "decisions": ["Ship Friday"],
            "action_items": [], "open_questions": [], "sections": [], "follow_up_email": "",
        ])
        let service = SummaryService(service: claude)
        let (summary, usage) = try await service.summarize(
            playbook: .standup, context: SessionContext(), transcript: makeTranscript(lines: 4).transcript,
            notes: nil, thread: [], startedAt: .now, duration: 600, model: "claude-sonnet-5-5")
        #expect(summary.title == "Weekly sync")
        #expect(summary.decisions == ["Ship Friday"])
        #expect(usage.role == "summary")
        #expect(usage.costUSD > 0)
    }

    @Test func retriesTransientFailuresThenGivesUp() async {
        let claude = MockClaude(failure: .invalidRequest("bad"))
        let service = SummaryService(service: claude)
        await #expect(throws: AnthropicError.invalidRequest("bad")) {
            _ = try await service.summarize(
                playbook: .general, context: SessionContext(), transcript: makeTranscript(lines: 2).transcript,
                notes: nil, thread: [], startedAt: .now, duration: 60, model: "m")
        }
        #expect(claude.requests.count == 1)
    }
}
