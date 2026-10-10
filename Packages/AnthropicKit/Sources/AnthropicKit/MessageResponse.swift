import Foundation

/// A complete (non-streaming) Messages API response.
public struct MessageResponse: Sendable, Decodable, Equatable {
    public let id: String
    public let model: String
    public let content: [ResponseBlock]
    public let stopReason: String?
    public let usage: TokenUsage

    enum CodingKeys: String, CodingKey {
        case id, model, content, usage
        case stopReason = "stop_reason"
    }

    /// All text blocks joined.
    public var text: String {
        content.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }

    /// The first tool call, if any.
    public var firstToolUse: (name: String, input: JSONValue)? {
        for block in content {
            if case .toolUse(_, let name, let input) = block { return (name, input) }
        }
        return nil
    }
}

/// Response content blocks Saaa reads; anything else is kept as `.other`.
public enum ResponseBlock: Sendable, Decodable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case thinking(String)
    case other(String)

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, thinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: (try? container.decode(JSONValue.self, forKey: .input)) ?? .object([:]))
        case "thinking":
            self = .thinking((try? container.decode(String.self, forKey: .thinking)) ?? "")
        default:
            self = .other(type)
        }
    }
}
