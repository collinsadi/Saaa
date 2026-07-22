import Foundation
import Matching

/// The installed-agent roster and the routing rule from issue #1: a project
/// goes to the agent that knows it, the user default breaks ties, and every
/// other installed agent lines up behind as automatic fallback.
public struct AgentRegistry: Sendable {

    /// Order doubles as the neutral fallback order.
    public let providers: [any AgentProvider]

    public init(providers: [any AgentProvider]) {
        self.providers = providers
    }

    public static var standard: AgentRegistry {
        AgentRegistry(providers: [ClaudeCodeProvider(), CodexProvider()])
    }

    /// Providers whose binary exists on disk. Auth is not pre-flighted here;
    /// an auth failure during a run surfaces as an error and falls through
    /// to the next attempt.
    public func installedProviders() -> [any AgentProvider] {
        providers.filter { $0.isInstalled() }
    }

    /// Ordered judgment attempts for one call.
    /// - Exactly one installed agent knows the top candidate: it leads.
    /// - Several (or none) know it: the user's preferred agent leads if
    ///   installed, else registry order decides.
    public func attemptOrder(
        topCandidateKnownTo knownTo: Set<String>,
        preferred: AgentID?,
        from installed: [any AgentProvider]
    ) -> [any AgentProvider] {
        guard !installed.isEmpty else { return [] }
        let knowers = installed.filter { knownTo.contains($0.id.rawValue) }

        let primary: any AgentProvider = if knowers.count == 1 {
            knowers[0]
        } else if let preferred,
                  let match = (knowers.isEmpty ? installed : knowers)
                      .first(where: { $0.id == preferred }) {
            match
        } else {
            (knowers.isEmpty ? installed : knowers)[0]
        }
        return [primary] + installed.filter { $0.id != primary.id }
    }

    /// Merges each provider's known projects into one candidate list:
    /// same directory = one candidate that unions provenance and memory
    /// flags. "Which tool knows this project" then feeds routing and the
    /// judgment prompt.
    public static func mergedCandidates(
        from providerCandidates: [[ProjectCandidate]]
    ) -> [ProjectCandidate] {
        var byPath: [URL: ProjectCandidate] = [:]
        var order: [URL] = []
        for candidates in providerCandidates {
            for candidate in candidates {
                if var existing = byPath[candidate.path] {
                    existing.knownTo.formUnion(candidate.knownTo)
                    existing.hasClaudeMD = existing.hasClaudeMD || candidate.hasClaudeMD
                    existing.hasAgentsMD = existing.hasAgentsMD || candidate.hasAgentsMD
                    byPath[candidate.path] = existing
                } else {
                    byPath[candidate.path] = candidate
                    order.append(candidate.path)
                }
            }
        }
        return order.compactMap { byPath[$0] }
    }
}
