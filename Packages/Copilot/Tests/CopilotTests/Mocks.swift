import AnthropicKit
import Core
import Foundation
import Transcription
@testable import Copilot

/// Scripted Claude: records requests, streams canned text.
final class MockClaude: ClaudeService, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MessageRequest] = []
    var reply: String
    var failure: AnthropicError?
    var structuredValue: JSONValue
    var chunkDelay: Duration

    init(reply: String = "Say: we can start the pilot next week.", structuredValue: JSONValue = [:], failure: AnthropicError? = nil, chunkDelay: Duration = .milliseconds(5)) {
        self.reply = reply
        self.structuredValue = structuredValue
        self.failure = failure
        self.chunkDelay = chunkDelay
    }

    var requests: [MessageRequest] { lock.withLock { recorded } }

    func streamText(_ request: MessageRequest, deadline: Duration) -> AsyncThrowingStream<TextStreamEvent, Error> {
        lock.withLock { recorded.append(request) }
        let reply = self.reply
        let failure = self.failure
        let delay = chunkDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(model: request.model))
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    continuation.yield(.text(String(word) + " "))
                }
                continuation.yield(.finished(StreamResult(
                    model: request.model, stopReason: "end_turn",
                    usage: TokenUsage(inputTokens: 300, outputTokens: 40, cacheReadTokens: 2_000),
                    timeToFirstToken: .milliseconds(700), duration: .milliseconds(1_200))))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func structured(_ request: MessageRequest, schema: JSONValue, deadline: Duration) async throws -> (value: JSONValue, result: StreamResult) {
        lock.withLock { recorded.append(request) }
        if let failure { throw failure }
        return (structuredValue, StreamResult(
            model: request.model, stopReason: "end_turn",
            usage: TokenUsage(inputTokens: 5_000, outputTokens: 600),
            timeToFirstToken: nil, duration: .seconds(4)))
    }

    func prewarm() async {}
}

/// A transcript with `count` alternating settled lines, 5 s apart.
func makeTranscript(lines count: Int, startingAt offset: Int = 0) -> LiveTranscript {
    var transcript = LiveTranscript()
    for index in offset..<(offset + count) {
        transcript.commit(index.isMultiple(of: 2) ? .them : .me,
                          start: Double(index) * 5, end: Double(index) * 5 + 4,
                          text: "Line number \(index) about topic \(index * 7)")
    }
    return transcript
}

func text(of block: ContentBlock) -> String {
    if case .text(let text) = block { return text.text }
    return ""
}

func cacheControl(of block: ContentBlock) -> CacheControl? {
    if case .text(let text) = block { return text.cacheControl }
    return nil
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
