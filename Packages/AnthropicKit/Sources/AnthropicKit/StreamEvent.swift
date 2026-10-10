import Foundation

/// A decoded Messages API stream event. Mid-stream `error` events are not
/// represented here; the decoder throws them as ``AnthropicError``.
public enum StreamEvent: Sendable, Equatable {
    public enum BlockKind: Sendable, Equatable {
        case text
        case toolUse(id: String, name: String)
        case thinking
        case other(String)
    }

    case messageStart(id: String, model: String, usage: TokenUsage)
    case contentBlockStart(index: Int, kind: BlockKind)
    case textDelta(index: Int, text: String)
    case inputJSONDelta(index: Int, partialJSON: String)
    case thinkingDelta(index: Int, text: String)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, usage: TokenUsage?)
    case messageStop
    case ping
    /// New event types the API may add later; ignored by consumers.
    case unknown(String)
}

/// Turns raw SSE events into ``StreamEvent``s.
public enum StreamEventDecoder {

    public static func decode(_ sse: ServerSentEvent) throws -> StreamEvent {
        let data = Data(sse.data.utf8)
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw AnthropicError.malformed("undecodable event \(sse.event ?? "?")")
        }
        let type = envelope.type ?? sse.event ?? ""
        switch type {
        case "message_start":
            guard let message = envelope.message else {
                throw AnthropicError.malformed("message_start without message")
            }
            return .messageStart(
                id: message.id ?? "",
                model: message.model ?? "",
                usage: message.usage?.usage ?? .zero)
        case "content_block_start":
            let block = envelope.contentBlock
            let kind: StreamEvent.BlockKind = switch block?.type {
            case "text": .text
            case "tool_use": .toolUse(id: block?.id ?? "", name: block?.name ?? "")
            case "thinking": .thinking
            default: .other(block?.type ?? "unknown")
            }
            return .contentBlockStart(index: envelope.index ?? 0, kind: kind)
        case "content_block_delta":
            let index = envelope.index ?? 0
            switch envelope.delta?.type {
            case "text_delta":
                return .textDelta(index: index, text: envelope.delta?.text ?? "")
            case "input_json_delta":
                return .inputJSONDelta(index: index, partialJSON: envelope.delta?.partialJSON ?? "")
            case "thinking_delta":
                return .thinkingDelta(index: index, text: envelope.delta?.thinking ?? "")
            default:
                return .unknown("delta:\(envelope.delta?.type ?? "?")")
            }
        case "content_block_stop":
            return .contentBlockStop(index: envelope.index ?? 0)
        case "message_delta":
            return .messageDelta(
                stopReason: envelope.delta?.stopReason,
                usage: envelope.usage?.usage)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            throw AnthropicError.fromStreamError(
                type: envelope.error?.type,
                message: envelope.error?.message ?? "stream error")
        default:
            return .unknown(type)
        }
    }

    private struct Envelope: Decodable {
        struct MessageInfo: Decodable {
            let id: String?
            let model: String?
            let usage: TokenUsage.Wire?
        }

        struct Block: Decodable {
            let type: String?
            let id: String?
            let name: String?
        }

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let partialJSON: String?
            let thinking: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking
                case partialJSON = "partial_json"
                case stopReason = "stop_reason"
            }
        }

        struct ErrorInfo: Decodable {
            let type: String?
            let message: String?
        }

        let type: String?
        let index: Int?
        let message: MessageInfo?
        let contentBlock: Block?
        let delta: Delta?
        let usage: TokenUsage.Wire?
        let error: ErrorInfo?

        enum CodingKeys: String, CodingKey {
            case type, index, message, delta, usage, error
            case contentBlock = "content_block"
        }
    }
}
