import Foundation
import Testing
@testable import AnthropicKit

@Suite struct LineSplitterTests {

    @Test func splitsAllTerminatorsAndKeepsEmptyLines() {
        var splitter = LineSplitter()
        let produced = splitter.push(contentsOf: Array("a\nb\r\nc\rd\n\ne".utf8))
        #expect(produced == ["a", "b", "c", "d", ""])
        #expect(splitter.finish() == "e")
        #expect(splitter.finish() == nil)
    }

    @Test func crlfSplitAcrossChunksIsOneTerminator() {
        var splitter = LineSplitter()
        #expect(splitter.push(contentsOf: Array("x\r".utf8)) == ["x"])
        #expect(splitter.push(contentsOf: Array("\ny\n".utf8)) == ["y"])
    }

    @Test func multibyteUTF8SurvivesChunking() {
        var splitter = LineSplitter()
        let bytes = Array("café ✓\n".utf8)
        var out: [String] = []
        for byte in bytes { if let line = splitter.push(byte) { out.append(line) } }
        #expect(out == ["café ✓"])
    }
}

@Suite struct SSEParserTests {

    @Test func parsesTheDocumentedStream() throws {
        var parser = SSEParser()
        let events = lines(documentedStream).compactMap { parser.feed($0) }
        #expect(events.count == 8)
        #expect(events.first?.event == "message_start")
        #expect(events.last?.event == "message_stop")
        #expect(events[3].data.contains("\"Hello\""))
    }

    @Test func joinsMultipleDataLinesAndSkipsComments() {
        var parser = SSEParser()
        #expect(parser.feed(": keep-alive") == nil)
        #expect(parser.feed("event: custom") == nil)
        #expect(parser.feed("data: one") == nil)
        #expect(parser.feed("data:two") == nil)
        #expect(parser.feed("") == ServerSentEvent(event: "custom", data: "one\ntwo"))
        // Blank line with nothing buffered dispatches nothing.
        #expect(parser.feed("") == nil)
    }

    @Test func finishFlushesAnUnterminatedEvent() {
        var parser = SSEParser()
        _ = parser.feed("data: {}")
        #expect(parser.finish() == ServerSentEvent(event: nil, data: "{}"))
    }
}

@Suite struct StreamEventDecoderTests {

    @Test func decodesEveryDocumentedEvent() throws {
        var parser = SSEParser()
        let decoded = try lines(documentedStream)
            .compactMap { parser.feed($0) }
            .map(StreamEventDecoder.decode)
        #expect(decoded == [
            .messageStart(
                id: "msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY", model: "claude-opus-5-5",
                usage: TokenUsage(inputTokens: 25, outputTokens: 1)),
            .contentBlockStart(index: 0, kind: .text),
            .ping,
            .textDelta(index: 0, text: "Hello"),
            .textDelta(index: 0, text: "!"),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn", usage: TokenUsage(outputTokens: 15)),
            .messageStop,
        ])
    }

    @Test func errorEventThrowsTypedError() {
        let event = ServerSentEvent(
            event: "error",
            data: #"{"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}"#)
        #expect(throws: AnthropicError.overloaded) {
            try StreamEventDecoder.decode(event)
        }
    }

    @Test func toolUseAndJSONDeltas() throws {
        let start = try StreamEventDecoder.decode(ServerSentEvent(
            event: "content_block_start",
            data: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"record","input":{}}}"#))
        #expect(start == .contentBlockStart(index: 1, kind: .toolUse(id: "toolu_1", name: "record")))
        let delta = try StreamEventDecoder.decode(ServerSentEvent(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}"#))
        #expect(delta == .inputJSONDelta(index: 1, partialJSON: #"{"a":"#))
    }

    @Test func unknownEventsAreTolerated() throws {
        let event = try StreamEventDecoder.decode(ServerSentEvent(
            event: "brand_new", data: #"{"type":"brand_new"}"#))
        #expect(event == .unknown("brand_new"))
    }

    @Test func cacheUsageDecodesFromMessageStart() throws {
        let event = try StreamEventDecoder.decode(ServerSentEvent(
            event: "message_start",
            data: #"{"type":"message_start","message":{"id":"m","model":"claude-haiku-5-5","usage":{"input_tokens":12,"output_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":100}}}}"#))
        #expect(event == .messageStart(
            id: "m", model: "claude-haiku-5-5",
            usage: TokenUsage(
                inputTokens: 12, outputTokens: 1, cacheReadTokens: 900,
                cacheWrite5mTokens: 200, cacheWrite1hTokens: 100)))
    }
}
