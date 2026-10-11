import AnthropicKit
import Core
import Foundation
import Testing
import Transcription
@testable import Copilot

@Suite struct PromptComposerTests {

    static let context = SessionContext(
        title: "Acme renewal", goal: "Keep them on the annual plan",
        participants: "Dana Lee (CFO), Ken", notes: "They asked about SSO last time.")

    static var playbook: Playbook {
        var playbook = Playbook.sales
        playbook.vocabulary = ["Okta", "Northwind"]
        playbook.knowledge = [KnowledgeItem(name: "Pricing.md", text: "Team plan: $24 per seat per month.")]
        return playbook
    }

    let composer = PromptComposer(playbook: PromptComposerTests.playbook, context: PromptComposerTests.context)

    @Test func systemPromptCarriesPlaybookContextVocabularyAndKnowledge() {
        let system = composer.liveSystemPrompt
        #expect(system.contains("Playbook: Sales"))
        #expect(system.contains("My goal: Keep them on the annual plan"))
        #expect(system.contains("Okta"))
        #expect(system.contains("Dana Lee"))
        #expect(system.contains("<document name=\"Pricing.md\">"))
        #expect(system.contains("Never invent"))
    }

    @Test func liveRequestShapesCachingAndDisablesThinking() throws {
        var transcript = makeTranscript(lines: 30)
        transcript.setPartial(.them, start: 151, end: 153, text: "what does SSO cost")
        let request = composer.liveRequest(
            .action(StandardActions.answer, focus: "What does SSO cost?"),
            transcript: transcript, now: 155, recent: [], model: "claude-haiku-5-5")
        #expect(request.cacheBreakpointCount == 2)
        #expect(request.thinking == .disabled)
        #expect(request.temperature == nil)
        #expect(request.system.first?.cacheControl != nil)
        let blocks = try #require(request.messages.first?.content)
        // 30 lines, settled before 149 s → lines 0...29 at 0..145 s: all settled, 2 full chunks of 12.
        #expect(blocks.count == 3)
        #expect(cacheControl(of: blocks[0]) == nil)
        #expect(cacheControl(of: blocks[1]) != nil)
        let tail = text(of: blocks[2])
        #expect(tail.contains("(still speaking)"))
        #expect(tail.contains("The question they just asked: \"What does SSO cost?\""))
        #expect(tail.contains("Task: Answer the most recent question"))
        #expect(text(of: blocks[0]).hasPrefix("Live transcript"))
    }

    @Test func cachedChunksStayByteIdenticalAsTheCallGrows() throws {
        let early = makeTranscript(lines: 26)
        let later = makeTranscript(lines: 40)
        let first = composer.liveRequest(.ask("Where are we?"), transcript: early, now: 140, recent: [], model: "m")
        let second = composer.liveRequest(.ask("And now?"), transcript: later, now: 210, recent: [], model: "m")
        let a = try #require(first.messages.first?.content)
        let b = try #require(second.messages.first?.content)
        // Every cached chunk from the first request reappears unchanged.
        let firstCached = a.filter { cacheControl(of: $0) != nil || a.firstIndex(of: $0)! < a.count - 1 }
        for (index, block) in firstCached.enumerated() where index < b.count - 1 {
            #expect(text(of: block) == text(of: b[index]))
        }
        // And the breakpoint moved forward to the newest full chunk.
        let cachedIndexes = b.indices.filter { cacheControl(of: b[$0]) != nil }
        #expect(cachedIndexes == [b.count - 2])
        #expect(second.cacheBreakpointCount <= 4)
    }

    @Test func recentLinesStayInTheUncachedTail() throws {
        let transcript = makeTranscript(lines: 13)  // last line starts at 60 s
        let request = composer.liveRequest(.ask("x"), transcript: transcript, now: 62, recent: [], model: "m")
        let blocks = try #require(request.messages.first?.content)
        // Only 12 lines are older than 56 s: exactly one full chunk is cached.
        #expect(blocks.count == 2)
        #expect(text(of: blocks[1]).contains("Line number 12"))
        #expect(!text(of: blocks[0]).contains("Line number 12"))
    }

    @Test func emptyCallSaysSo() throws {
        let request = composer.liveRequest(.ask("Hi?"), transcript: LiveTranscript(), now: 0, recent: [], model: "m")
        let blocks = try #require(request.messages.first?.content)
        #expect(blocks.count == 1)
        #expect(text(of: blocks[0]).contains("(nothing has been said yet)"))
        #expect(request.cacheBreakpointCount == 1)
    }

    @Test func recentSuggestionsAreListedButNotForRefinements() throws {
        let recent = [CopilotExchange(kind: .action, title: "Answer", response: "We support Okta SSO.", callTime: 10)]
        let normal = composer.liveRequest(.ask("x"), transcript: makeTranscript(lines: 3), now: 30, recent: recent, model: "m")
        #expect(text(of: try #require(normal.messages.first?.content.last)).contains("Your recent suggestions"))
        let refine = composer.liveRequest(
            .refine(previous: "We support Okta SSO.", refinement: .moreDetail),
            transcript: makeTranscript(lines: 3), now: 30, recent: recent, model: "m")
        let tail = text(of: try #require(refine.messages.first?.content.last))
        #expect(!tail.contains("Your recent suggestions"))
        #expect(tail.contains("Give more detail"))
    }

    @Test func notesRequestCarriesCurrentNotesAndFormat() throws {
        let previous = LiveNotes(keyPoints: ["Budget 50k"])
        let request = composer.notesRequest(transcript: makeTranscript(lines: 5), now: 40, previous: previous, model: "m")
        let tail = text(of: try #require(request.messages.first?.content.last))
        #expect(tail.contains("- Budget 50k"))
        #expect(tail.contains("ACTION ITEMS:"))
        #expect(request.system.first?.text == composer.liveSystemPrompt)
    }

    @Test func summaryRequestIsStrictAndPlaybookShaped() throws {
        let transcript = makeTranscript(lines: 6).transcript
        let (request, schema) = composer.summaryRequest(
            transcript: transcript, notes: LiveNotes(decisions: ["Annual plan"]), thread: [],
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), duration: 1_800, model: "claude-sonnet-5-5")
        let body = text(of: try #require(request.messages.first?.content.first))
        #expect(body.contains("\"Pain points\""))
        #expect(body.contains("follow_up_email: a short, warm follow-up email"))
        #expect(body.contains("Running notes taken during the call"))
        #expect(body.contains("30 minutes"))
        Self.assertStrict(schema)
        #expect(request.thinking == nil)
        #expect(!request.stream || request.stream)  // structured() forces non-streaming
    }

    static func assertStrict(_ schema: JSONValue) {
        if schema["type"]?.stringValue == "object" {
            #expect(schema["additionalProperties"] == .bool(false))
            let properties = schema["properties"]?.objectKeys ?? []
            let required = Set(schema["required"]?.stringArray ?? [])
            #expect(Set(properties) == required)
            for key in properties { assertStrict(schema["properties"]?[key] ?? .null) }
        }
        if let items = schema["items"] { assertStrict(items) }
    }

    @Test func decodesTheStructuredSummary() {
        let value: JSONValue = [
            "title": "Acme renewal: SSO blocker",
            "tldr": "They renew if SSO ships by May.",
            "key_points": ["Usage up 30%"],
            "decisions": [],
            "action_items": [["text": "Send SSO timeline", "owner": "Me", "due": "Friday"], ["text": " ", "owner": "", "due": ""]],
            "open_questions": ["Who signs?"],
            "sections": [["title": "Pain points", "bullets": ["Manual provisioning"]], ["title": "", "bullets": []]],
            "follow_up_email": "",
        ]
        let summary = PromptComposer.decodeSummary(value, model: "claude-sonnet-5-5")
        #expect(summary.title == "Acme renewal: SSO blocker")
        #expect(summary.actionItems.count == 1)
        #expect(summary.actionItems.first?.owner == "Me")
        #expect(summary.sections.map(\.title) == ["Pain points"])
        #expect(summary.followUpEmail == nil)
    }

    @Test func notesTrackTheChecklistOnlyWhenThePlaybookHasOne() throws {
        let request = composer.notesRequest(transcript: makeTranscript(lines: 5), now: 40, previous: LiveNotes(covered: ["Budget"]), model: "m")
        let tail = text(of: try #require(request.messages.first?.content.last))
        #expect(tail.contains("Under COVERED, list the items from my checklist"))
        #expect(tail.contains("\"Decision maker\""))
        #expect(tail.contains("COVERED:\n- Budget"))
        #expect(tail.hasSuffix("COVERED:\n- checklist item"))

        let plain = PromptComposer(playbook: .general, context: Self.context)
        let general = plain.notesRequest(transcript: makeTranscript(lines: 5), now: 40, previous: nil, model: "m")
        #expect(!text(of: try #require(general.messages.first?.content.last)).contains("COVERED"))
    }

    @Test func summaryAsksForTheChecklistAndCoachingWithTheStats() throws {
        let transcript = makeTranscript(lines: 6).transcript
        let (request, _) = composer.summaryRequest(
            transcript: transcript, notes: nil, thread: [], startedAt: .now, duration: 600, model: "m")
        let body = text(of: try #require(request.messages.first?.content.first))
        #expect(body.contains("checklist: exactly these items, in order: \"Their main pain\", \"Budget\""))
        #expect(body.contains("coaching: feedback for me on how I ran this call"))
        #expect(body.contains("I talked "))

        let plain = PromptComposer(playbook: .general, context: Self.context)
        let (general, _) = plain.summaryRequest(
            transcript: transcript, notes: nil, thread: [], startedAt: .now, duration: 600, model: "m")
        let generalBody = text(of: try #require(general.messages.first?.content.first))
        #expect(generalBody.contains("checklist: return an empty array."))
        #expect(generalBody.contains("coaching: return empty arrays."))
    }

    @Test func decodesTheChecklistAndCoaching() {
        let value: JSONValue = [
            "title": "Acme", "tldr": "", "key_points": [], "decisions": [], "action_items": [], "open_questions": [],
            "sections": [], "follow_up_email": "",
            "checklist": [
                ["item": "Budget", "covered": true, "evidence": " $50k approved "],
                ["item": "Timeline", "covered": false, "evidence": ""],
                ["item": " ", "covered": true, "evidence": "x"],
            ],
            "coaching": ["went_well": ["Clear agenda"], "try_next": ["Ask about the decision maker earlier", " "]],
        ]
        let summary = PromptComposer.decodeSummary(value, model: "m")
        #expect(summary.checklist == [
            ChecklistResult(item: "Budget", covered: true, evidence: "$50k approved"),
            ChecklistResult(item: "Timeline", covered: false),
        ])
        #expect(summary.coaching == CoachingFeedback(wentWell: ["Clear agenda"], tryNext: ["Ask about the decision maker earlier"]))

        var empty = value
        if case .object(var object) = empty {
            object["checklist"] = []
            object["coaching"] = ["went_well": [], "try_next": []]
            empty = .object(object)
        }
        let plain = PromptComposer.decodeSummary(empty, model: "m")
        #expect(plain.checklist == nil)
        #expect(plain.coaching == nil)
    }

    @Test func chatCachesTheReferenceAndKeepsTurns() throws {
        let material = PromptComposer.ChatMaterial(
            title: "Acme", startedAt: .now, transcript: makeTranscript(lines: 4).transcript, summary: nil,
            notes: LiveNotes(keyPoints: ["x"]))
        let history = [ChatTurn(role: .user, text: "Who owns the follow-up?"), ChatTurn(role: .assistant, text: "You do.")]
        let request = composer.chatRequest(material: material, history: history, question: "By when?", model: "m")
        #expect(request.messages.count == 3)
        #expect(request.cacheBreakpointCount == 1)
        #expect(text(of: try #require(request.messages.first?.content.first)).contains("Transcript"))
        #expect(text(of: try #require(request.messages.last?.content.first)) == "By when?")
        let fresh = composer.chatRequest(material: material, history: [], question: "Summarize", model: "m")
        #expect(fresh.messages.count == 1)
        #expect(text(of: try #require(fresh.messages.first?.content.last)) == "Question: Summarize")
    }
}

extension JSONValue {
    var objectKeys: [String]? {
        if case .object(let object) = self { return Array(object.keys) }
        return nil
    }
}
