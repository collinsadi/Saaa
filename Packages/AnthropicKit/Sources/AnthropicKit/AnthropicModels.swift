import Foundation

/// Per-million-token prices in USD.
public struct ModelPricing: Sendable, Equatable, Codable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    /// Prompts above this many tokens bill at `longContext` (Haiku 5.5 only).
    public var longContextThreshold: Int?
    public var longContextMultiplier: Double

    public init(
        input: Double, output: Double, cacheWrite5m: Double, cacheWrite1h: Double,
        cacheRead: Double, longContextThreshold: Int? = nil, longContextMultiplier: Double = 1
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.longContextThreshold = longContextThreshold
        self.longContextMultiplier = longContextMultiplier
    }

    /// USD cost of one request's usage. A request is priced on its own: past
    /// the long-context threshold every token category pays the higher rate.
    public func cost(of usage: TokenUsage) -> Double {
        var multiplier = 1.0
        if let threshold = longContextThreshold, usage.totalInputTokens > threshold {
            multiplier = longContextMultiplier
        }
        let dollars = Double(usage.inputTokens) * input
            + Double(usage.outputTokens) * output
            + Double(usage.cacheWrite5mTokens) * cacheWrite5m
            + Double(usage.cacheWrite1hTokens) * cacheWrite1h
            + Double(usage.cacheReadTokens) * cacheRead
        return dollars * multiplier / 1_000_000
    }
}

/// One Claude model Saaa knows how to price and describe.
public struct ClaudeModel: Sendable, Hashable, Codable, Identifiable {
    public enum Speed: String, Sendable, Codable {
        case fastest, fast, moderate
    }

    public let id: String
    public let displayName: String
    public let shortName: String
    public let speed: Speed
    public let pricing: ModelPricing
}

/// The models Saaa offers. IDs change when Anthropic ships new versions;
/// they live here and nowhere else, and Settings can override any role
/// with an exact ID without a rebuild.
public enum ModelCatalog {
    /// Published prices, verified 2026-10-11.
    public static let haiku = ClaudeModel(
        id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", shortName: "Haiku 5.5",
        speed: .fastest,
        pricing: ModelPricing(
            input: 0.10, output: 0.50, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01,
            longContextThreshold: 100_000, longContextMultiplier: 5))
    public static let sonnet = ClaudeModel(
        id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", shortName: "Sonnet 5.5",
        speed: .fast,
        pricing: ModelPricing(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.10))
    public static let opus = ClaudeModel(
        id: "claude-opus-5-5", displayName: "Claude Opus 5.5", shortName: "Opus 5.5",
        speed: .moderate,
        pricing: ModelPricing(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20))

    public static let all: [ClaudeModel] = [haiku, sonnet, opus]

    public static func model(id: String) -> ClaudeModel? {
        all.first { $0.id == id }
    }

    /// Cost of usage on a model id; unknown ids are priced as Sonnet so the
    /// ledger never under-reports.
    public static func cost(of usage: TokenUsage, modelID: String) -> Double {
        (model(id: modelID) ?? sonnet).pricing.cost(of: usage)
    }
}

/// What a request is for. Each role maps to a model the user can change.
public enum ModelRole: String, Sendable, CaseIterable, Codable {
    /// Live answers and quick actions (latency first).
    case live
    /// Running notes during the call.
    case notes
    /// The post-call summary.
    case summary
    /// Ask this call, after the meeting.
    case chat

    public var defaultModel: ClaudeModel {
        switch self {
        case .live, .notes: ModelCatalog.haiku
        case .summary, .chat: ModelCatalog.sonnet
        }
    }

    public var defaultsKey: String { "model.\(rawValue)" }

    public var displayName: String {
        switch self {
        case .live: "Live answers"
        case .notes: "Live notes"
        case .summary: "Summaries"
        case .chat: "Ask this call"
        }
    }

    /// The model id for this role: a stored override, else the default.
    public func modelID(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultModel.id : stored
    }
}
