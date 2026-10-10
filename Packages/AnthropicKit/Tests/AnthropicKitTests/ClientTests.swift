import Foundation
import Testing
@testable import AnthropicKit

@Suite struct ClientStreamingTests {

    @Test func streamTextYieldsDeltasAndMergedUsage() async throws {
        let transport = MockTransport.sse(documentedStream)
        var text = ""
        var finished: StreamResult?
        for try await event in client(transport).streamText(sampleRequest) {
            switch event {
            case .text(let piece): text += piece
            case .finished(let result): finished = result
            case .started: break
            }
        }
        #expect(text == "Hello!")
        #expect(finished?.stopReason == "end_turn")
        #expect(finished?.usage == TokenUsage(inputTokens: 25, outputTokens: 15))
        #expect(finished?.model == "claude-opus-5-5")
        #expect(finished?.timeToFirstToken != nil)
    }

    @Test func requestCarriesHeadersAndStreamFlag() async throws {
        let transport = MockTransport.sse(documentedStream)
        for try await _ in client(transport).events(sampleRequest) {}
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "x-api-key")?.hasPrefix("sk-ant-") == true)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("\"stream\":true"))
    }

    @Test func unauthorizedMapsFromStatus() async {
        let transport = MockTransport.sse(
            #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#,
            status: 401)
        await #expect(throws: AnthropicError.unauthorized("invalid x-api-key")) {
            for try await _ in client(transport).events(sampleRequest) {}
        }
    }

    @Test func rateLimitReadsRetryAfter() async {
        let transport = MockTransport.sse(
            #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#,
            status: 429, headers: ["retry-after": "7"])
        await #expect(throws: AnthropicError.rateLimited(retryAfter: 7)) {
            for try await _ in client(transport).events(sampleRequest) {}
        }
    }

    @Test func overloadedStatusAndMidStreamError() async {
        let busy = MockTransport.sse("", status: 529)
        await #expect(throws: AnthropicError.overloaded) {
            for try await _ in client(busy).events(sampleRequest) {}
        }
        let midStream = MockTransport.sse("""
        event: message_start
        data: {"type":"message_start","message":{"id":"m","model":"claude-haiku-5-5","usage":{"input_tokens":3,"output_tokens":1}}}

        event: error
        data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}


        """)
        await #expect(throws: AnthropicError.overloaded) {
            for try await _ in client(midStream).events(sampleRequest) {}
        }
    }

    @Test func truncatedStreamIsANetworkError() async {
        let transport = MockTransport.sse("""
        event: message_start
        data: {"type":"message_start","message":{"id":"m","model":"claude-haiku-5-5","usage":{"input_tokens":3,"output_tokens":1}}}


        """)
        await #expect(throws: AnthropicError.network("stream ended before message_stop")) {
            for try await _ in client(transport).events(sampleRequest) {}
        }
    }

    @Test func missingKeyFailsBeforeAnyRequest() async {
        let transport = MockTransport.sse(documentedStream)
        let keyless = AnthropicClient(transport: transport) { throw AnthropicError.missingAPIKey }
        await #expect(throws: AnthropicError.missingAPIKey) {
            for try await _ in keyless.events(sampleRequest) {}
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func deadlineTimesOutAHangingStream() async {
        let transport = MockTransport([.head(status: 200, headers: [:])], hangAfterScript: true)
        await #expect(throws: AnthropicError.timedOut) {
            for try await _ in client(transport).events(sampleRequest, deadline: .milliseconds(200)) {}
        }
    }

    @Test func consumerCancellationTearsDownTheTransport() async throws {
        let slow = MockTransport(
            [.head(status: 200, headers: [:])] + lines(documentedStream).map { .line($0) },
            delay: .milliseconds(30))
        let task = Task {
            var pieces = 0
            for try await event in client(slow).streamText(sampleRequest) {
                if case .text = event { pieces += 1 }
            }
            return pieces
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(slow.terminations == 1)
    }
}

@Suite struct ClientNonStreamingTests {

    static let toolResponse = #"""
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"{\"title\":\"Weekly sync\",\"decisions\":[\"Ship Friday\"]}"}],"usage":{"input_tokens":1200,"output_tokens":80,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
    """#

    static let schema = JSONValue.strictObject([
        "title": .string(),
        "decisions": .array(of: .string()),
    ])

    @Test func sendDecodesAResponse() async throws {
        let transport = MockTransport.sse(Self.toolResponse)
        let response = try await client(transport).send(sampleRequest)
        #expect(response.model == "claude-sonnet-5-5")
        #expect(response.usage.inputTokens == 1200)
        let body = try #require(transport.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!body.contains("\"stream\""))
    }

    @Test func structuredParsesTheJSONReplyAndSendsTheFormat() async throws {
        let transport = MockTransport.sse(Self.toolResponse)
        let (value, result) = try await client(transport).structured(sampleRequest, schema: Self.schema)
        #expect(value["title"]?.stringValue == "Weekly sync")
        #expect(value["decisions"]?.stringArray == ["Ship Friday"])
        #expect(result.usage.outputTokens == 80)
        let body = try #require(transport.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains(#""output_config":{"format":{"schema":"#))
        #expect(body.contains(#""additionalProperties":false"#))
        #expect(body.contains(#""type":"json_schema""#))
    }

    @Test func structuredRejectsNonJSONAndTruncation() async {
        let prose = MockTransport.sse(#"""
        {"id":"m","model":"claude-sonnet-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}
        """#)
        await #expect(throws: AnthropicError.malformed("structured output was not valid JSON")) {
            _ = try await client(prose).structured(sampleRequest, schema: Self.schema)
        }
        let cut = MockTransport.sse(#"""
        {"id":"m","model":"claude-sonnet-5-5","stop_reason":"max_tokens","content":[{"type":"text","text":"{\"title\":"}],"usage":{"input_tokens":1,"output_tokens":1}}
        """#)
        await #expect(throws: AnthropicError.malformed("structured output was cut off by max_tokens")) {
            _ = try await client(cut).structured(sampleRequest, schema: Self.schema)
        }
    }
}
