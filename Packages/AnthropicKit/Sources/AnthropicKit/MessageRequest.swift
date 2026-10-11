import Foundation

/// `POST /v1/messages` body. Encodes snake_case with sorted keys so equal
/// requests produce byte-identical JSON (prompt caching depends on it).
public struct MessageRequest: Sendable, Encodable, Equatable {
    public var model: String
    public var maxTokens: Int
    /// System prompt as text blocks, so a cache breakpoint can sit on any of them.
    public var system: [TextBlock]
    public var messages: [Message]
    public var stream: Bool
    public var temperature: Double?
    public var tools: [Tool]?
    public var toolChoice: ToolChoice?
    public var thinking: Thinking?
    public var stopSequences: [String]?
    public var metadata: Metadata?
    /// Effort and structured-output format (`output_config`).
    public var outputConfig: OutputConfig?

    public init(
        model: String,
        maxTokens: Int,
        system: [TextBlock] = [],
        messages: [Message],
        stream: Bool = true,
        temperature: Double? = nil,
        tools: [Tool]? = nil,
        toolChoice: ToolChoice? = nil,
        thinking: Thinking? = nil,
        stopSequences: [String]? = nil,
        metadata: Metadata? = nil,
        outputConfig: OutputConfig? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.tools = tools
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.stopSequences = stopSequences
        self.metadata = metadata
        self.outputConfig = outputConfig
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, messages, stream, temperature, tools
        case toolChoice = "tool_choice"
        case thinking
        case stopSequences = "stop_sequences"
        case metadata
        case outputConfig = "output_config"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        if !system.isEmpty { try container.encode(system, forKey: .system) }
        try container.encode(messages, forKey: .messages)
        if stream { try container.encode(true, forKey: .stream) }
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(stopSequences, forKey: .stopSequences)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
    }

    /// The exact bytes sent on the wire.
    public func encodedBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Number of `cache_control` breakpoints (the API allows at most 4).
    public var cacheBreakpointCount: Int {
        let systemCount = system.filter { $0.cacheControl != nil }.count
        let messageCount = messages.reduce(0) { total, message in
            total + message.content.filter(\.hasCacheControl).count
        }
        let toolCount = (tools ?? []).filter { $0.cacheControl != nil }.count
        return systemCount + messageCount + toolCount
    }
}

public enum Role: String, Sendable, Codable, Equatable {
    case user
    case assistant
}

public struct Message: Sendable, Codable, Equatable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text(TextBlock(text))])
    }

    public static func assistant(_ text: String) -> Message {
        Message(role: .assistant, content: [.text(TextBlock(text))])
    }
}

/// Prompt-cache marker. `ttl` nil means the 5-minute default.
public struct CacheControl: Sendable, Codable, Equatable {
    public enum TTL: String, Sendable, Codable {
        case fiveMinutes = "5m"
        case oneHour = "1h"
    }

    public var type: String
    public var ttl: TTL?

    public init(ttl: TTL? = nil) {
        self.type = "ephemeral"
        self.ttl = ttl
    }

    public static let ephemeral = CacheControl()
}

public struct TextBlock: Sendable, Codable, Equatable {
    public var text: String
    public var cacheControl: CacheControl?

    public init(_ text: String, cacheControl: CacheControl? = nil) {
        self.text = text
        self.cacheControl = cacheControl
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        cacheControl = try container.decodeIfPresent(CacheControl.self, forKey: .cacheControl)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }
}

/// Request content blocks.
public enum ContentBlock: Sendable, Codable, Equatable {
    case text(TextBlock)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    /// A text block, optionally carrying a cache breakpoint.
    public static func plain(_ string: String, cache: CacheControl? = nil) -> ContentBlock {
        .text(TextBlock(string, cacheControl: cache))
    }

    var hasCacheControl: Bool {
        if case .text(let block) = self { return block.cacheControl != nil }
        return false
    }

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case cacheControl = "cache_control"
        case toolUseID = "tool_use_id"
        case isError = "is_error"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try TextBlock(from: decoder))
        case "tool_use":
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(JSONValue.self, forKey: .input))
        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: (try? container.decode(String.self, forKey: .content)) ?? "",
                isError: (try? container.decode(Bool.self, forKey: .isError)) ?? false)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unsupported block \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .toolUse(let id, let name, let input):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            if isError { try container.encode(true, forKey: .isError) }
        }
    }
}

/// A client tool definition (used here to force structured JSON output).
public struct Tool: Sendable, Encodable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var cacheControl: CacheControl?

    public init(name: String, description: String, inputSchema: JSONValue, cacheControl: CacheControl? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.cacheControl = cacheControl
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }
}

/// How the model may use tools. The 5.5 models reject `.any` and `.tool`
/// (forced tool use); for guaranteed JSON use `AnthropicClient.structured`.
public enum ToolChoice: Sendable, Encodable, Equatable {
    case auto
    case any
    case tool(String)
    case none

    enum CodingKeys: String, CodingKey { case type, name }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try container.encode("auto", forKey: .type)
        case .any: try container.encode("any", forKey: .type)
        case .none: try container.encode("none", forKey: .type)
        case .tool(let name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Extended thinking. Live answers turn it off: the latency budget has no
/// room for it.
public enum Thinking: Sendable, Encodable, Equatable {
    case disabled
    case adaptive
    case enabled(budgetTokens: Int)

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled: try container.encode("disabled", forKey: .type)
        case .adaptive: try container.encode("adaptive", forKey: .type)
        case .enabled(let budget):
            try container.encode("enabled", forKey: .type)
            try container.encode(budget, forKey: .budgetTokens)
        }
    }
}

/// `output_config`: effort level and structured-output format.
public struct OutputConfig: Sendable, Encodable, Equatable {
    public enum Effort: String, Sendable, Encodable {
        case low, medium, high, xhigh, max
    }

    public var effort: Effort?
    public var format: OutputFormat?

    public init(effort: Effort? = nil, format: OutputFormat? = nil) {
        self.effort = effort
        self.format = format
    }
}

/// Structured output: the reply is JSON matching `schema` (objects must set
/// `additionalProperties: false`; see ``JSONValue/strictObject(_:required:)``).
public struct OutputFormat: Sendable, Encodable, Equatable {
    public var type: String
    public var schema: JSONValue

    public static func jsonSchema(_ schema: JSONValue) -> OutputFormat {
        OutputFormat(type: "json_schema", schema: schema)
    }
}

/// Opaque request metadata. Never put personal data here.
public struct Metadata: Sendable, Encodable, Equatable {
    public var userID: String

    public init(userID: String) {
        self.userID = userID
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}
