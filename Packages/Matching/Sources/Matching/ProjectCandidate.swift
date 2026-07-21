import Foundation

/// A local project Claude Code has memory of — a candidate home for a call.
public struct ProjectCandidate: Sendable, Equatable, Identifiable, Codable {
    /// The project's working directory.
    public let path: URL
    public var name: String
    /// True if the project has a CLAUDE.md (deeper Claude memory).
    public var hasClaudeMD: Bool
    /// Profile vocabulary: name parts, CLAUDE.md/README headings, top-level
    /// file names — used by the prefilter and the Whisper bias.
    public var profileTerms: [String]

    public var id: URL { path }

    public init(path: URL, name: String, hasClaudeMD: Bool, profileTerms: [String]) {
        self.path = path
        self.name = name
        self.hasClaudeMD = hasClaudeMD
        self.profileTerms = profileTerms
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
