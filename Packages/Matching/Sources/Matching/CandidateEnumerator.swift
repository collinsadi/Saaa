import Foundation
import os

/// Enumerates projects Claude Code has memory of by inspecting the local
/// store (`~/.claude/projects/*` session logs carry each project's real
/// `cwd`), then profiling each project directory. Resilient to layout drift:
/// anything unreadable is skipped, and Phase 6 can additionally ask `claude`
/// itself to enumerate.
public struct CandidateEnumerator: Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "CandidateEnumerator")

    private let claudeRoot: URL
    private var fileManager: FileManager { .default }

    /// `claudeRoot` defaults to `~/.claude`; injectable for tests.
    public init(claudeRoot: URL? = nil) {
        self.claudeRoot = claudeRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// All distinct, still-existing project directories with a profile each.
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
            candidates.append(profile(standardized))
        }
        return candidates.sorted { $0.name < $1.name }
    }

    /// Reads the newest session log's first JSON line and extracts `"cwd"`.
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
            guard let handle = try? FileHandle(forReadingFrom: log),
                  let head = try? handle.read(upToCount: 1 << 16) else { continue }
            try? handle.close()
            for lineData in head.split(separator: UInt8(ascii: "\n")).prefix(5) {
                if let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                   let cwd = object["cwd"] as? String, cwd.hasPrefix("/") {
                    return URL(filePath: cwd)
                }
            }
        }
        return nil
    }

    /// Builds the profile vocabulary for one project directory.
    private func profile(_ path: URL) -> ProjectCandidate {
        var terms: [String] = path.lastPathComponent
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        let claudeMD = path.appendingPathComponent("CLAUDE.md")
        let hasClaudeMD = fileManager.fileExists(atPath: claudeMD.path)
        for docName in ["CLAUDE.md", "README.md", "ARCHITECTURE.md"] {
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
            profileTerms: terms)
    }
}
