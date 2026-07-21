import CryptoKit
import Foundation

/// The result of attempting one file change.
public enum WriteOutcome: Sendable, Equatable {
    case applied(targetFile: String)
    /// The file changed between preview and apply — nothing was written;
    /// `diff` shows what is on disk now vs. what the preview assumed.
    case conflict(targetFile: String, diff: String)
    case failed(targetFile: String, reason: String)
}

/// A previewed change: exactly what apply() will do, plus a fingerprint of
/// the file state the preview was computed against.
public struct PreviewedChange: Sendable, Equatable {
    public let change: FileChange
    /// Full file content after the change (what review shows).
    public let resultingContent: String
    /// SHA-256 of the file content the preview was based on ("" = absent).
    public let baseFingerprint: String
}

/// Applies planned changes inside one project, additively and never
/// clobbering: a file that changed since preview produces a conflict with a
/// diff instead of a write.
public struct WriteBackEngine: Sendable {

    private let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    // MARK: - Preview

    public func preview(_ change: FileChange) -> PreviewedChange {
        let url = projectRoot.appendingPathComponent(change.targetFile)
        let existing = (try? String(contentsOf: url, encoding: .utf8))
        let resulting: String
        if let existing {
            resulting = existing.hasSuffix("\n") || existing.isEmpty
                ? existing + change.content
                : existing + "\n" + change.content
        } else {
            resulting = change.header.isEmpty
                ? change.content
                : change.header + change.content
        }
        return PreviewedChange(
            change: change,
            resultingContent: resulting,
            baseFingerprint: Self.fingerprint(existing))
    }

    // MARK: - Apply

    /// Applies previewed changes one by one; each is independently verified
    /// against its fingerprint immediately before writing.
    public func apply(_ previews: [PreviewedChange]) -> [WriteOutcome] {
        previews.map { apply($0) }
    }

    private func apply(_ preview: PreviewedChange) -> WriteOutcome {
        let target = preview.change.targetFile
        let url = projectRoot.appendingPathComponent(target)
        let current = (try? String(contentsOf: url, encoding: .utf8))

        guard Self.fingerprint(current) == preview.baseFingerprint else {
            return .conflict(
                targetFile: target,
                diff: Self.diff(previewBase: preview, currentContent: current))
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try preview.resultingContent.write(to: url, atomically: true, encoding: .utf8)
            return .applied(targetFile: target)
        } catch {
            return .failed(targetFile: target, reason: String(describing: error))
        }
    }

    // MARK: - Internals

    static func fingerprint(_ content: String?) -> String {
        guard let content else { return "" }
        return SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// A compact conflict diff: the lines present now that the preview did
    /// not expect (and vice versa), trimmed to the changed region.
    static func diff(previewBase preview: PreviewedChange, currentContent: String?) -> String {
        let expectedBase = String(
            preview.resultingContent.dropLast(preview.change.content.count))
        let expected = expectedBase.split(separator: "\n", omittingEmptySubsequences: false)
        let actual = (currentContent ?? "").split(separator: "\n", omittingEmptySubsequences: false)

        var prefix = 0
        while prefix < min(expected.count, actual.count), expected[prefix] == actual[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(expected.count, actual.count) - prefix,
              expected[expected.count - 1 - suffix] == actual[actual.count - 1 - suffix] {
            suffix += 1
        }
        let removed = expected[prefix..<(expected.count - suffix)]
        let added = actual[prefix..<(actual.count - suffix)]
        var lines: [String] = ["@@ line \(prefix + 1) @@"]
        lines += removed.map { "- \($0)" }
        lines += added.map { "+ \($0)" }
        if currentContent == nil {
            lines = ["file was deleted since review"]
        }
        return lines.joined(separator: "\n")
    }
}
