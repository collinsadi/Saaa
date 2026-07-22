import ClaudeBridge
import Core
import Foundation
import Matching

/// Identity of a supported coding agent. Raw values are storage keys
/// (defaults, archives, candidate provenance) — never rename them.
public enum AgentID: String, CaseIterable, Sendable, Codable {
    case claudeCode = "claude"
    case codex = "codex"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Model choice expressed as intent, mapped to concrete model names per
/// provider by ``ModelMap``. `exact` is the advanced escape hatch.
public enum ModelIntent: Sendable, Equatable {
    case providerDefault
    case fast
    case best
    case exact(String)
}

/// Provider-neutral failures. Each maps to a defined fallback upstream:
/// try the next installed agent, else keep the transcript unfiled.
public enum AgentError: Error, Equatable {
    case notInstalled
    case notAuthenticated
    case runFailed(detail: String)
    case timedOut
    case malformedOutput(String)
}

/// One coding agent behind a uniform interface. A third provider is a
/// drop-in: implement this and append it to ``AgentRegistry/standard``.
public protocol AgentProvider: Sendable {
    var id: AgentID { get }
    var displayName: String { get }

    /// Local check only (binary on disk) — never network.
    func isInstalled() -> Bool

    /// Bounded live auth check. Used by onboarding and settings, not per
    /// call; per-call auth failures surface as ``AgentError/notAuthenticated``
    /// and trigger fallback.
    func verifyAuthenticated() async -> Bool

    /// Projects this agent has memory of, profiled and tagged with this
    /// agent's id. Reads local config and session logs only.
    func knownProjects() -> [ProjectCandidate]

    /// The read-only matching + extraction judgment. A non-nil
    /// `pinnedProject` means local evidence already decided the project and
    /// the agent only classifies and extracts (issue #7 escalation gate).
    func judge(
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        provenance: [String: [String]],
        calendar: CalendarContext?,
        pinnedProject: String?,
        model: ModelIntent,
        timeout: Duration
    ) async throws -> CallJudgment
}

/// User-facing filing preferences, read from defaults at judgment time so
/// changes apply without any settings-window plumbing.
public struct FilingPreferences: Sendable, Equatable {
    public static let agentKey = "filingAgent"
    public static let intentKey = "filingModelIntent"
    public static let exactModelKey = "filingExactModel"

    /// nil = automatic routing by which agent knows the project.
    public var preferredAgent: AgentID?
    public var modelIntent: ModelIntent

    public init(preferredAgent: AgentID? = nil, modelIntent: ModelIntent = .providerDefault) {
        self.preferredAgent = preferredAgent
        self.modelIntent = modelIntent
    }

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> FilingPreferences {
        let agent = AgentID(rawValue: defaults.string(forKey: agentKey) ?? "")
        let exact = defaults.string(forKey: exactModelKey)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let intent: ModelIntent = if !exact.isEmpty {
            .exact(exact)
        } else {
            switch defaults.string(forKey: intentKey) {
            case "fast": .fast
            case "best": .best
            default: .providerDefault
            }
        }
        return FilingPreferences(preferredAgent: agent, modelIntent: intent)
    }
}

/// Maps a model intent to the concrete name passed to each provider's CLI.
/// These are editable defaults, not gospel — the exact override always wins,
/// and nil means "let the provider use its own configured default".
public enum ModelMap {
    public static func modelName(for intent: ModelIntent, provider: AgentID) -> String? {
        switch intent {
        case .providerDefault: nil
        case .exact(let name): name
        case .fast: provider == .claudeCode ? "haiku" : "gpt-5.1-codex-mini"
        case .best: provider == .claudeCode ? "opus" : "gpt-5.1-codex"
        }
    }
}
