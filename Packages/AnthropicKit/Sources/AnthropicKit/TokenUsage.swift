import Foundation

/// Token accounting for one or more requests, including prompt-cache traffic.
public struct TokenUsage: Sendable, Equatable, Codable, Hashable {
    /// Uncached input tokens (after the last cache breakpoint).
    public var inputTokens: Int
    public var outputTokens: Int
    /// Tokens served from the prompt cache.
    public var cacheReadTokens: Int
    /// Tokens written to the 5-minute cache.
    public var cacheWrite5mTokens: Int
    /// Tokens written to the 1-hour cache.
    public var cacheWrite1hTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
    }

    public static let zero = TokenUsage()

    /// Every prompt token, cached or not.
    public var totalInputTokens: Int {
        inputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    /// Share of prompt tokens served from cache, 0...1.
    public var cacheHitRatio: Double {
        let total = totalInputTokens
        return total > 0 ? Double(cacheReadTokens) / Double(total) : 0
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWrite5mTokens: lhs.cacheWrite5mTokens + rhs.cacheWrite5mTokens,
            cacheWrite1hTokens: lhs.cacheWrite1hTokens + rhs.cacheWrite1hTokens)
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }

    /// Streaming usage arrives in pieces (`message_start`, then cumulative
    /// `message_delta`); the true total is the field-wise maximum.
    func merged(with other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            cacheReadTokens: max(cacheReadTokens, other.cacheReadTokens),
            cacheWrite5mTokens: max(cacheWrite5mTokens, other.cacheWrite5mTokens),
            cacheWrite1hTokens: max(cacheWrite1hTokens, other.cacheWrite1hTokens))
    }
}

extension TokenUsage {
    /// The API's `usage` object.
    struct Wire: Decodable {
        struct Creation: Decodable {
            let ephemeral5m: Int?
            let ephemeral1h: Int?

            enum CodingKeys: String, CodingKey {
                case ephemeral5m = "ephemeral_5m_input_tokens"
                case ephemeral1h = "ephemeral_1h_input_tokens"
            }
        }

        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheCreation: Creation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
        }

        var usage: TokenUsage {
            let write5m: Int
            let write1h: Int
            if let cacheCreation {
                write5m = cacheCreation.ephemeral5m ?? 0
                write1h = cacheCreation.ephemeral1h ?? 0
            } else {
                write5m = cacheCreationInputTokens ?? 0
                write1h = 0
            }
            return TokenUsage(
                inputTokens: inputTokens ?? 0,
                outputTokens: outputTokens ?? 0,
                cacheReadTokens: cacheReadInputTokens ?? 0,
                cacheWrite5mTokens: write5m,
                cacheWrite1hTokens: write1h)
        }
    }

    public init(from decoder: Decoder) throws {
        // Decodes both the API wire shape and Saaa's own stored shape.
        if let stored = try? StoredShape(from: decoder) {
            self = stored.usage
        } else {
            self = try Wire(from: decoder).usage
        }
    }

    public func encode(to encoder: Encoder) throws {
        try StoredShape(self).encode(to: encoder)
    }

    private struct StoredShape: Codable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite5m: Int
        let cacheWrite1h: Int

        init(_ usage: TokenUsage) {
            input = usage.inputTokens
            output = usage.outputTokens
            cacheRead = usage.cacheReadTokens
            cacheWrite5m = usage.cacheWrite5mTokens
            cacheWrite1h = usage.cacheWrite1hTokens
        }

        var usage: TokenUsage {
            TokenUsage(
                inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite5m, cacheWrite1hTokens: cacheWrite1h)
        }
    }
}
