import Foundation
import Synchronization
@testable import AnthropicKit

/// The documented example stream (Messages API streaming docs), verbatim.
let documentedStream = """
event: message_start
data: {"type": "message_start", "message": {"id": "msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

event: ping
data: {"type": "ping"}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "!"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence":null}, "usage": {"output_tokens": 15}}

event: message_stop
data: {"type": "message_stop"}


"""

func lines(_ text: String) -> [String] {
    var splitter = LineSplitter()
    var result = splitter.push(contentsOf: Array(text.utf8))
    if let rest = splitter.finish() { result.append(rest) }
    return result
}

/// Scripted transport: replays events, optionally slowly or forever.
final class MockTransport: HTTPTransport, Sendable {
    struct State {
        var requests: [URLRequest] = []
        var terminations = 0
    }

    let script: [TransportEvent]
    let delay: Duration?
    let hangAfterScript: Bool
    let state = Mutex(State())

    init(_ script: [TransportEvent], delay: Duration? = nil, hangAfterScript: Bool = false) {
        self.script = script
        self.delay = delay
        self.hangAfterScript = hangAfterScript
    }

    static func sse(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> MockTransport {
        MockTransport([.head(status: status, headers: headers)] + lines(text).map { .line($0) })
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var terminations: Int { state.withLock { $0.terminations } }

    func send(_ request: URLRequest) -> AsyncThrowingStream<TransportEvent, Error> {
        state.withLock { $0.requests.append(request) }
        let script = self.script
        let delay = self.delay
        let hang = self.hangAfterScript
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in script {
                    if let delay { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                if hang { try? await Task.sleep(for: .seconds(120)) }
                continuation.finish()
            }
            continuation.onTermination = { [self] _ in
                task.cancel()
                self.state.withLock { $0.terminations += 1 }
            }
        }
    }
}

func client(_ transport: MockTransport, key: String = "sk-ant-test-key-0000000000000000000000000000") -> AnthropicClient {
    AnthropicClient(apiKey: key, transport: transport)
}

let sampleRequest = MessageRequest(
    model: ModelCatalog.haiku.id, maxTokens: 64, messages: [.user("Hi")])
