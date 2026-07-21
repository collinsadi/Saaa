import Foundation

/// Chooses which app the "Them" lane should tap when the hotkey fires.
/// Pure ranking over injected candidates — unit-tested without the HAL.
public enum TargetPicker {

    /// One running app that is a Core Audio client (or owns one).
    public struct Candidate: Sendable, Equatable {
        public let pid: pid_t
        public let bundleID: String?
        public let name: String
        public let isPlayingAudio: Bool

        public init(pid: pid_t, bundleID: String?, name: String, isPlayingAudio: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.isPlayingAudio = isPlayingAudio
        }
    }

    /// Bundle-ID prefixes of known conferencing apps and the browsers that
    /// host web calls. Order = preference among otherwise-equal candidates.
    public static let knownConferencingPrefixes: [String] = [
        "us.zoom",
        "com.microsoft.teams",
        "Cisco-Systems.Spark",
        "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.apple.Safari",
    ]

    /// Ranking: audio-active conferencing app → any audio-active app →
    /// conferencing app that is merely running → nil (caller surfaces a
    /// picker or error; never guess a silent non-conferencing app).
    public static func pick(from candidates: [Candidate]) -> Candidate? {
        func conferencingRank(_ candidate: Candidate) -> Int? {
            guard let bundleID = candidate.bundleID else { return nil }
            return knownConferencingPrefixes.firstIndex { bundleID.hasPrefix($0) }
        }
        let playing = candidates.filter(\.isPlayingAudio)
        if let best = playing
            .compactMap({ c in conferencingRank(c).map { (c, $0) } })
            .min(by: { $0.1 < $1.1 })?.0 {
            return best
        }
        if let anyPlaying = playing.first {
            return anyPlaying
        }
        return candidates
            .compactMap { c in conferencingRank(c).map { (c, $0) } }
            .min { $0.1 < $1.1 }?.0
    }
}
