import AnthropicKit
import Core
import Foundation

/// Writes the post-call summary (structured output), retrying transient
/// failures once.
public struct SummaryService: Sendable {

    private let service: any ClaudeService

    public init(service: any ClaudeService) {
        self.service = service
    }

    public func summarize(
        playbook: Playbook,
        context: SessionContext,
        transcript: Transcript,
        notes: LiveNotes?,
        thread: [CopilotExchange],
        startedAt: Date,
        duration: TimeInterval,
        model: String = ModelRole.summary.modelID()
    ) async throws -> (summary: MeetingSummary, usage: UsageRecord) {
        let composer = PromptComposer(playbook: playbook, context: context)
        let (request, schema) = composer.summaryRequest(
            transcript: transcript, notes: notes, thread: thread,
            startedAt: startedAt, duration: duration, model: model)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (value, result) = try await service.structured(request, schema: schema, deadline: .seconds(150))
                var summary = PromptComposer.decodeSummary(value, model: result.model)
                if summary.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    summary.title = context.title.isEmpty ? "Meeting" : context.title
                }
                return (summary, UsageRecord(role: .summary, result: result))
            } catch let error as AnthropicError where error.isRetryable && attempt < 3 {
                let wait: Duration = if case .rateLimited(let after) = error, let after {
                    .seconds(min(after, 20))
                } else {
                    .seconds(2 * attempt)
                }
                try await Task.sleep(for: wait)
            }
        }
    }
}

/// "Ask this call": streaming answers about a finished session.
public struct MeetingChat: Sendable {

    private let service: any ClaudeService

    public init(service: any ClaudeService) {
        self.service = service
    }

    public func ask(
        _ question: String,
        history: [ChatTurn],
        material: PromptComposer.ChatMaterial,
        playbook: Playbook,
        context: SessionContext,
        model: String = ModelRole.chat.modelID()
    ) -> AsyncThrowingStream<TextStreamEvent, Error> {
        let composer = PromptComposer(playbook: playbook, context: context)
        let request = composer.chatRequest(material: material, history: history, question: question, model: model)
        return service.streamText(request, deadline: .seconds(90))
    }
}
