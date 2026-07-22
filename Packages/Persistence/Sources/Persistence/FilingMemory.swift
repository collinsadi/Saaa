import Foundation
import Matching

/// Learned filing signals (issue #7), fed by CONFIRMED write-backs only:
/// recurring-meeting -> project links, and a running per-project centroid of
/// call vectors so future similar calls boost that project. Meeting titles
/// and derived vectors are call content, so the store is sealed with the
/// same AES-GCM key as session archives, and the user can clear it from
/// Settings at any time.
public struct FilingMemory: Sendable {

    struct Payload: Codable {
        var meetingProjects: [String: String] = [:]
        var projectVectors: [String: VectorStat] = [:]
    }

    struct VectorStat: Codable {
        var mean: [Double]
        var count: Int
    }

    /// New calls keep influencing the centroid even after many samples.
    static let centroidWindow = 32

    private let encryption: EncryptionService
    private let url: URL

    public init(encryption: EncryptionService, directory: URL? = nil) {
        self.encryption = encryption
        let base = directory ?? URL.applicationSupportDirectory
            .appendingPathComponent("Saaa", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("filing-memory.enc")
    }

    // MARK: - Lookups

    public func projectPath(forMeeting title: String) -> String? {
        load().meetingProjects[Self.normalized(title)]
    }

    /// Cosine similarity of a call vector against every learned project
    /// centroid.
    public func similarities(to vector: [Double]) -> [String: Double] {
        load().projectVectors.mapValues {
            TranscriptEmbedder.cosine(vector, $0.mean)
        }
    }

    // MARK: - Learning

    public func rememberMeeting(_ title: String, project: String) {
        let key = Self.normalized(title)
        guard !key.isEmpty else { return }
        var payload = load()
        payload.meetingProjects[key] = project
        save(payload)
    }

    public func rememberVector(_ vector: [Double], project: String) {
        guard !vector.isEmpty else { return }
        var payload = load()
        if var stat = payload.projectVectors[project], stat.mean.count == vector.count {
            let count = min(stat.count, Self.centroidWindow)
            for index in vector.indices {
                stat.mean[index] = (stat.mean[index] * Double(count) + vector[index])
                    / Double(count + 1)
            }
            stat.count += 1
            payload.projectVectors[project] = stat
        } else {
            payload.projectVectors[project] = VectorStat(mean: vector, count: 1)
        }
        save(payload)
    }

    /// Forgets everything (Settings action).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Store

    static func normalized(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() -> Payload {
        (try? encryption.decrypt(Payload.self, from: url)) ?? Payload()
    }

    private func save(_ payload: Payload) {
        try? encryption.encrypt(payload, to: url)
    }
}
