import Foundation
import os

/// Enumerates projects Claude Code has memory of by inspecting the local
/// store (`~/.claude/projects/*` session logs carry each project's real
/// `cwd`), then profiling each project directory. Also provides the generic
/// pieces other agents' enumerations reuse: the recursive session-log
/// scanner and the directory profiler. Resilient to layout drift: anything
/// unreadable is skipped.
public struct CandidateEnumerator: Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "CandidateEnumerator")

    private let claudeRoot: URL
    private var fileManager: FileManager { .default }

    /// `claudeRoot` defaults to `~/.claude`; injectable for tests.
    public init(claudeRoot: URL? = nil) {
        self.claudeRoot = claudeRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// All distinct, still-existing project directories Claude Code knows,
    /// with a profile each, tagged with claude provenance.
    public func enumerate() -> [ProjectCandidate] {
        let projectsDir = claudeRoot.appendingPathComponent("projects")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

        var seen = Set<URL>()
        var candidates: [ProjectCandidate] = []
        for entry in entries {
            guard let cwd = Self.projectPath(fromSessionLogsIn: entry) else { continue }
            let standardized = cwd.standardizedFileURL
            guard seen.insert(standardized).inserted,
                  fileManager.fileExists(atPath: standardized.path) else { continue }
            candidates.append(profile(standardized, knownTo: ["claude"]))
        }
        return candidates.sorted { $0.name < $1.name }
    }

    /// Reads the newest session log's first JSON lines and extracts `cwd`.
    static func projectPath(fromSessionLogsIn directory: URL) -> URL? {
        let fm = FileManager.default
        guard let logs = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "jsonl" }) else { return nil }
        let newestFirst = logs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for log in newestFirst {
            if let cwd = cwdFromLogHead(log) { return cwd }
        }
        return nil
    }

    /// Generic recursive scan for agents whose session logs nest by date
    /// (Codex: `sessions/YYYY/MM/DD/rollout-*.jsonl`). Returns distinct,
    /// still-existing project directories. Bounded so a huge history cannot
    /// stall enumeration.
    public static func projectPaths(
        underSessionRoot root: URL, maxFiles: Int = 512
    ) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var scanned = 0
        var seen = Set<URL>()
        var paths: [URL] = []
        for case let file as URL in walker {
            guard file.pathExtension == "jsonl" else { continue }
            scanned += 1
            if scanned > maxFiles { break }
            guard let cwd = cwdFromLogHead(file) else { continue }
            let standardized = cwd.standardizedFileURL
            guard seen.insert(standardized).inserted,
                  fm.fileExists(atPath: standardized.path) else { continue }
            paths.append(standardized)
        }
        return paths.sorted { $0.path < $1.path }
    }

    /// Scans a log's first lines for a `cwd`, searching one level of nesting
    /// too (Codex wraps it in a `payload` object).
    static func cwdFromLogHead(_ log: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: log),
              let head = try? handle.read(upToCount: 1 << 16) else { return nil }
        try? handle.close()
        for lineData in head.split(separator: UInt8(ascii: "\n")).prefix(5) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData))
                as? [String: Any] else { continue }
            if let cwd = findCwd(in: object, depth: 2), cwd.hasPrefix("/") {
                return URL(filePath: cwd)
            }
        }
        return nil
    }

    private static func findCwd(in object: [String: Any], depth: Int) -> String? {
        if let cwd = object["cwd"] as? String { return cwd }
        guard depth > 0 else { return nil }
        for value in object.values {
            if let nested = value as? [String: Any],
               let cwd = findCwd(in: nested, depth: depth - 1) {
                return cwd
            }
        }
        return nil
    }

    /// Builds the profile vocabulary for one project directory, tagged with
    /// the enumerating agent's provenance.
    public func profile(_ path: URL, knownTo: Set<String>) -> ProjectCandidate {
        var terms: [String] = path.lastPathComponent
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        let hasClaudeMD = fileManager.fileExists(
            atPath: path.appendingPathComponent("CLAUDE.md").path)
        let hasAgentsMD = fileManager.fileExists(
            atPath: path.appendingPathComponent("AGENTS.md").path)
        for docName in ["CLAUDE.md", "AGENTS.md", "README.md", "ARCHITECTURE.md"] {
            let url = path.appendingPathComponent(docName)
            guard let data = try? FileHandle(forReadingFrom: url).read(upToCount: 1 << 14) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            // Headings + emphasized identifiers carry the domain vocabulary.
            for line in text.split(separator: "\n") where line.hasPrefix("#") {
                terms += line.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            }
        }
        if let children = try? fileManager.contentsOfDirectory(atPath: path.path) {
            terms += children
                .filter { !$0.hasPrefix(".") }
                .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        }
        return ProjectCandidate(
            path: path,
            name: path.lastPathComponent,
            hasClaudeMD: hasClaudeMD,
            hasAgentsMD: hasAgentsMD,
            profileTerms: terms,
            knownTo: knownTo)
    }
}
