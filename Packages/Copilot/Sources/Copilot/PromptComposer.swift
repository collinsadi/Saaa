import AnthropicKit
import Core
import Foundation
import Transcription

/// Builds every Claude request Saaa makes, shaped for prompt caching:
///
///     system  [rules + playbook + context + knowledge]   ← breakpoint 1 (stable all call)
///     user    [transcript chunk 1] … [chunk k]            ← breakpoint 2 on chunk k
///             [open chunk + in-progress words + task]     ← uncached tail
///
/// Chunks hold a fixed number of *settled* lines (older than `settleDelay`,
/// so both lanes have finalized), so a chunk's text never changes once
/// emitted and each request finds the previous one's cache entry.
public struct PromptComposer: Sendable {

    public enum LiveTask: Sendable, Equatable {
        /// A quick action; `focus` is a detected question to answer.
        case action(QuickAction, focus: String?)
        /// The user's own question.
        case ask(String)
        /// Rework an earlier answer.
        case refine(previous: String, refinement: Refinement)
    }

    /// Answers are short by default; these rework one on request.
    public enum Refinement: String, Sendable, Equatable, CaseIterable {
        case moreDetail
        case retry

        public var title: String {
            switch self {
            case .moreDetail: "More detail"
            case .retry: "Try again"
            }
        }
    }

    public var playbook: Playbook
    public var context: SessionContext
    public var linesPerChunk: Int
    public var settleDelay: TimeInterval
    /// Knowledge budget (characters) across all documents.
    public var knowledgeBudget: Int

    /// About 60K tokens: room for real reference material while a long call
    /// stays under Haiku's 100K long-context price step.
    public static let defaultKnowledgeBudget = 240_000

    public init(
        playbook: Playbook, context: SessionContext,
        linesPerChunk: Int = 12, settleDelay: TimeInterval = 6, knowledgeBudget: Int = defaultKnowledgeBudget
    ) {
        self.playbook = playbook
        self.context = context
        self.linesPerChunk = linesPerChunk
        self.settleDelay = settleDelay
        self.knowledgeBudget = knowledgeBudget
    }

    // MARK: - Live answers

    public func liveRequest(
        _ task: LiveTask,
        transcript: LiveTranscript,
        now: TimeInterval,
        recent: [CopilotExchange],
        model: String,
        maxTokens: Int = 500
    ) -> MessageRequest {
        let blocks = transcriptBlocks(transcript, now: now)
        var tail = blocks.tail
        let previous = recent.filter { $0.failure == nil && !$0.response.isEmpty }.suffix(3)
        if !previous.isEmpty, !isRefine(task) {
            tail += "\n\nYour recent suggestions (don't repeat them):\n"
            tail += previous.map { "- \($0.title): \(Self.oneLine($0.response, limit: 220))" }.joined(separator: "\n")
        }
        tail += "\n\n---\n" + taskText(task)
        return MessageRequest(
            model: model,
            maxTokens: maxTokens,
            system: [TextBlock(liveSystemPrompt, cacheControl: .ephemeral)],
            messages: [Message(role: .user, content: blocks.cached + [.plain(tail)])],
            thinking: .disabled)
    }

    func taskText(_ task: LiveTask) -> String {
        switch task {
        case .action(let action, let focus):
            var text = "Task: \(action.instruction)"
            if let focus, !focus.isEmpty {
                text += "\nThe question they just asked: \"\(focus)\""
            }
            return text
        case .ask(let question):
            return """
            Task: Answer my question about this call, briefly and directly. If it's about something \
            outside the call, answer from general knowledge and say so.
            My question: \(question)
            """
        case .refine(let previous, let refinement):
            let how = switch refinement {
            case .moreDetail: "Give more detail and the reasoning behind it, still easy to read at a glance (under 120 words)."
            case .retry: "Give a different, better answer to the same need, just as short."
            }
            return """
            Your previous suggestion was:
            \(previous)

            Task: \(how)
            """
        }
    }

    private func isRefine(_ task: LiveTask) -> Bool {
        if case .refine = task { return true }
        return false
    }

    // MARK: - Live notes

    public func notesRequest(
        transcript: LiveTranscript,
        now: TimeInterval,
        previous: LiveNotes?,
        model: String
    ) -> MessageRequest {
        let blocks = transcriptBlocks(transcript, now: now)
        let current = previous?.plainText ?? LiveNotes().plainText
        let tail = blocks.tail + """


        ---
        Task: Update the running notes for this call. Keep every still-relevant item from the \
        current notes, correct anything the conversation changed, and add what's new. Short \
        fragments with exact names, numbers and owners. At most 8 items per heading.

        Current notes:
        \(current)

        Reply in exactly this format and nothing else. Write "- (none)" under an empty heading.
        KEY POINTS:
        - item
        DECISIONS:
        - item
        ACTION ITEMS:
        - item (owner)
        OPEN QUESTIONS:
        - item
        """
        return MessageRequest(
            model: model,
            maxTokens: 900,
            system: [TextBlock(liveSystemPrompt, cacheControl: .ephemeral)],
            messages: [Message(role: .user, content: blocks.cached + [.plain(tail)])],
            thinking: .disabled)
    }

    // MARK: - Summary

    /// The post-call summary request (structured output) and its schema.
    public func summaryRequest(
        transcript: Transcript,
        notes: LiveNotes?,
        thread: [CopilotExchange],
        startedAt: Date,
        duration: TimeInterval,
        model: String
    ) -> (request: MessageRequest, schema: JSONValue) {
        var body = "Meeting date: \(startedAt.formatted(date: .complete, time: .shortened)). "
        body += "Length: \(max(1, Int((duration / 60).rounded()))) minutes.\n\n"
        body += "Transcript (Me = the user; Them = the other side):\n"
        body += transcript.segments.isEmpty
            ? "(no speech was transcribed)"
            : transcript.segments.map { Self.line($0) }.joined(separator: "\n")
        if let notes, !notes.isEmpty {
            body += "\n\nRunning notes taken during the call:\n\(notes.plainText)"
        }
        let useful = thread.filter { $0.failure == nil && !$0.response.isEmpty }
        if !useful.isEmpty {
            body += "\n\nCopilot suggestions given to the user during the call:\n"
            body += useful.suffix(20).map { "- [\(CallTime.stamp($0.callTime))] \($0.title): \(Self.oneLine($0.response, limit: 300))" }
                .joined(separator: "\n")
        }
        let sections = playbook.summarySections
        var task = """


        ---
        Task: Write the summary of this meeting for me.
        - title: short and specific (at most 8 words), e.g. "Acme renewal: SSO blocker".
        - tldr: one or two sentences on the outcome.
        - key_points, decisions, open_questions: concise, specific bullets (empty arrays when none).
        - action_items: every commitment, with owner (a name, "Me" for me, or "") and due ("" if none said).
        """
        if sections.isEmpty {
            task += "\n- sections: return an empty array."
        } else {
            task += "\n- sections: exactly these, in order, each with concise bullets (empty bullets if nothing was said): \(sections.map { "\"\($0)\"" }.joined(separator: ", "))."
        }
        if playbook.draftsFollowUpEmail {
            task += "\n- follow_up_email: a short, warm follow-up email from me to the other side, plain text, with a greeting and sign-off placeholder [Your name]. Only include commitments actually made."
        } else {
            task += "\n- follow_up_email: return an empty string."
        }
        task += "\nNever invent facts, numbers or owners that weren't said."
        let request = MessageRequest(
            model: model,
            maxTokens: 4_000,
            system: [TextBlock(summarySystemPrompt)],
            messages: [.user(body + task)])
        return (request, Self.summarySchema)
    }

    public static let summarySchema: JSONValue = {
        let strings = JSONValue.array(of: .string())
        let actionItem = JSONValue.strictObject([
            "text": .string(),
            "owner": .string(described: "Name of the owner, or empty"),
            "due": .string(described: "Due date as said, or empty"),
        ])
        let section = JSONValue.strictObject([
            "title": .string(),
            "bullets": strings,
        ])
        return JSONValue.strictObject([
            "title": .string(described: "Short, specific meeting title"),
            "tldr": .string(described: "The outcome in one or two sentences"),
            "key_points": strings,
            "decisions": strings,
            "action_items": .array(of: actionItem),
            "open_questions": strings,
            "sections": .array(of: section),
            "follow_up_email": .string(described: "Plain-text email, or empty"),
        ])
    }()

    /// Decodes the structured summary reply.
    public static func decodeSummary(_ value: JSONValue, model: String) -> MeetingSummary {
        MeetingSummary(
            title: value["title"]?.stringValue ?? "Meeting",
            tldr: value["tldr"]?.stringValue ?? "",
            keyPoints: value["key_points"]?.stringArray ?? [],
            decisions: value["decisions"]?.stringArray ?? [],
            actionItems: (value["action_items"]?.arrayValue ?? []).compactMap { item in
                guard let text = item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return MeetingSummary.ActionItem(
                    text: text, owner: item["owner"]?.stringValue, due: item["due"]?.stringValue)
            },
            openQuestions: value["open_questions"]?.stringArray ?? [],
            sections: (value["sections"]?.arrayValue ?? []).compactMap { section in
                guard let title = section["title"]?.stringValue, !title.isEmpty else { return nil }
                return MeetingSummary.Section(title: title, bullets: section["bullets"]?.stringArray ?? [])
            },
            followUpEmail: value["follow_up_email"]?.stringValue,
            generatedAt: .now,
            model: model)
    }

    // MARK: - Ask this call (after the meeting)

    public struct ChatMaterial: Sendable, Equatable {
        public var title: String
        public var startedAt: Date
        public var transcript: Transcript
        public var summary: MeetingSummary?
        public var notes: LiveNotes?

        public init(title: String, startedAt: Date, transcript: Transcript, summary: MeetingSummary?, notes: LiveNotes?) {
            self.title = title
            self.startedAt = startedAt
            self.transcript = transcript
            self.summary = summary
            self.notes = notes
        }
    }

    public func chatRequest(
        material: ChatMaterial,
        history: [ChatTurn],
        question: String,
        model: String
    ) -> MessageRequest {
        var reference = "Meeting: \(material.title) (\(material.startedAt.formatted(date: .abbreviated, time: .shortened)))\n\n"
        if let summary = material.summary {
            reference += "Summary:\n\(summary.markdown())\n\n"
        } else if let notes = material.notes, !notes.isEmpty {
            reference += "Notes:\n\(notes.plainText)\n\n"
        }
        reference += "Transcript (Me = the user; Them = the other side):\n"
        reference += material.transcript.segments.map { Self.line($0) }.joined(separator: "\n")
        var messages: [Message] = []
        // The reference rides in the first user turn, cached for follow-ups.
        let turns = history.suffix(12)
        var first = true
        for turn in turns {
            if first, turn.role == .user {
                messages.append(Message(role: .user, content: [
                    .plain(reference, cache: .ephemeral),
                    .plain("Question: \(turn.text)"),
                ]))
                first = false
            } else if !first {
                messages.append(Message(role: turn.role == .user ? .user : .assistant, content: [.plain(turn.text)]))
            }
        }
        if first {
            messages.append(Message(role: .user, content: [
                .plain(reference, cache: .ephemeral),
                .plain("Question: \(question)"),
            ]))
        } else {
            messages.append(.user(question))
        }
        return MessageRequest(
            model: model,
            maxTokens: 1_200,
            system: [TextBlock(chatSystemPrompt)],
            messages: messages)
    }

    // MARK: - System prompts

    /// Stable for the whole call (the first cache breakpoint).
    public var liveSystemPrompt: String {
        var parts: [String] = [Self.liveRules]
        parts.append("Playbook: \(playbook.name)\n\(playbook.instructions.trimmingCharacters(in: .whitespacesAndNewlines))")
        if let session = sessionText { parts.append(session) }
        let vocabulary = (playbook.vocabulary + context.vocabularyHints).uniqued()
        if !vocabulary.isEmpty {
            parts.append("Names and terms that may come up (the transcript may misspell them): \(vocabulary.joined(separator: ", "))")
        }
        if let knowledge = knowledgeText { parts.append(knowledge) }
        return parts.joined(separator: "\n\n")
    }

    static let liveRules = """
    You are Saaa, a real-time meeting copilot on the user's Mac. The user is the "Me" speaker on a \
    live call; everyone else is "Them". You read a live transcript and help the user in the moment.

    How to respond:
    - Be immediately usable. Start with the line the user can say or act on. No preamble, no \
    restating the question, no sign-off.
    - Be short. By default give one sentence the user can say or act on, two at most and under \
    40 words. Go longer only when the task asks for a list or for more detail. Plain text; "- " \
    bullets only for lists. No headings, no bold, no emoji.
    - When writing something to say out loud, write it in the user's voice, natural and spoken.
    - Ground claims in the transcript, the session details and the reference material. If a fact \
    isn't there and you aren't sure, say so in a few words instead of guessing. Never invent \
    numbers, prices, names, dates or commitments.
    - The transcript is machine-generated and can mishear words; infer the obvious meaning. Lines \
    marked "(still speaking)" are in progress.
    - You assist the user privately. Never address the other side directly.
    """

    var summarySystemPrompt: String {
        var parts = ["""
        You write meeting summaries for the user, who is the "Me" speaker. Be accurate and \
        specific: names, numbers, dates and owners exactly as they were said. Never invent facts. \
        Crisp, plain English; bullets are short phrases, not paragraphs.
        """]
        parts.append("Playbook: \(playbook.name)\n\(playbook.instructions)")
        if let session = sessionText { parts.append(session) }
        return parts.joined(separator: "\n\n")
    }

    var chatSystemPrompt: String {
        """
        You answer the user's questions about a past meeting they took part in (they are "Me"). \
        Use the meeting material provided. Quote or paraphrase what was actually said, with the \
        time stamp when helpful. If the meeting doesn't contain the answer, say so plainly. Be \
        concise; use short bullets for lists.
        """
    }

    var sessionText: String? {
        guard !context.isEmpty else { return nil }
        var lines = ["Session details from the user:"]
        func add(_ label: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append("\(label): \(trimmed)") }
        }
        add("Title", context.title)
        add("My goal", context.goal)
        add("Participants", context.participants)
        add("Notes", context.notes)
        return lines.joined(separator: "\n")
    }

    var knowledgeText: String? {
        guard !playbook.knowledge.isEmpty else { return nil }
        var budget = knowledgeBudget
        var documents: [String] = []
        for item in playbook.knowledge where budget > 0 {
            let text = String(item.text.prefix(budget))
            budget -= text.count
            documents.append("<document name=\"\(item.name)\">\n\(text)\n</document>")
        }
        return "Reference material from the user (use it for facts):\n" + documents.joined(separator: "\n")
    }

    // MARK: - Transcript rendering

    /// The cached transcript chunks and the uncached tail text.
    public func transcriptBlocks(_ transcript: LiveTranscript, now: TimeInterval) -> (cached: [ContentBlock], tail: String) {
        let header = "Live transcript ([mm:ss] from the start; Me = the user, Them = the other side):"
        let settled = transcript.settled(before: now - settleDelay)
        let fullChunks = settled.count / linesPerChunk
        var cached: [ContentBlock] = []
        for index in 0..<fullChunks {
            let start = settled.startIndex + index * linesPerChunk
            let lines = settled[start..<(start + linesPerChunk)].map(Self.line)
            var text = lines.joined(separator: "\n")
            if index == 0 { text = header + "\n" + text }
            let isLast = index == fullChunks - 1
            cached.append(.plain(text, cache: isLast ? .ephemeral : nil))
        }
        var tailLines: [String] = []
        if fullChunks == 0 { tailLines.append(header) }
        let remainderStart = settled.startIndex + fullChunks * linesPerChunk
        tailLines += settled[remainderStart...].map(Self.line)
        tailLines += transcript.unsettled(from: now - settleDelay).map(Self.line)
        for lane in LiveTranscript.Lane.allCases {
            if let partial = transcript.partials[lane] {
                tailLines.append("[\(CallTime.stamp(partial.start))] \(lane.label): \(partial.text) (still speaking)")
            }
        }
        if transcript.entries.isEmpty, transcript.partials.isEmpty {
            tailLines.append("(nothing has been said yet)")
        }
        return (cached, tailLines.joined(separator: "\n"))
    }

    static func line(_ entry: LiveTranscript.Entry) -> String {
        "[\(CallTime.stamp(entry.segment.start))] \(entry.lane.label): \(entry.segment.text)"
    }

    static func line(_ segment: TranscriptSegment) -> String {
        let who: String = switch segment.speaker {
        case .me: "Me"
        case .them(let label): label ?? "Them"
        }
        return "[\(CallTime.stamp(segment.start))] \(who): \(segment.text)"
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return compactMap { raw in
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty, seen.insert(item.lowercased()).inserted else { return nil }
            return item
        }
    }
}
