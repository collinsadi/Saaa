import Foundation

/// A local project some coding agent has memory of — a candidate home for a
/// call. `knownTo` carries which agents (by raw AgentID) know it; that
/// provenance routes the judgment and is itself a matching signal.
public struct ProjectCandidate: Sendable, Equatable, Identifiable, Codable {
    /// The project's working directory.
    public let path: URL
    public var name: String
    /// True if the project has a CLAUDE.md (deeper Claude Code memory).
    public var hasClaudeMD: Bool
    /// True if the project has an AGENTS.md (Codex project memory).
    public var hasAgentsMD: Bool
    /// Profile vocabulary: name parts, memory-file/README headings,
    /// top-level file names — used by the prefilter and the Whisper bias.
    public var profileTerms: [String]
    /// Raw agent ids that have session memory of this project.
    public var knownTo: Set<String>

    public var id: URL { path }

    public init(
        path: URL, name: String, hasClaudeMD: Bool, hasAgentsMD: Bool = false,
        profileTerms: [String], knownTo: Set<String> = []
    ) {
        self.path = path
        self.name = name
        self.hasClaudeMD = hasClaudeMD
        self.hasAgentsMD = hasAgentsMD
        self.profileTerms = profileTerms
        self.knownTo = knownTo
    }

    // Hand-written decode so archives sealed before provenance existed
    // still open (missing fields default instead of failing).
    enum CodingKeys: String, CodingKey {
        case path, name, hasClaudeMD, hasAgentsMD, profileTerms, knownTo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(URL.self, forKey: .path)
        name = try container.decode(String.self, forKey: .name)
        hasClaudeMD = try container.decode(Bool.self, forKey: .hasClaudeMD)
        hasAgentsMD = try container.decodeIfPresent(Bool.self, forKey: .hasAgentsMD) ?? false
        profileTerms = try container.decode([String].self, forKey: .profileTerms)
        knownTo = try container.decodeIfPresent(Set<String>.self, forKey: .knownTo) ?? []
    }
}

/// A prefilter result.
public struct ScoredCandidate: Sendable, Equatable, Codable {
    public let candidate: ProjectCandidate
    public let score: Double

    public init(candidate: ProjectCandidate, score: Double) {
        self.candidate = candidate
        self.score = score
    }
}
