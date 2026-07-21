import ClaudeBridge
import Foundation

/// One planned file mutation — always additive (append or create), never a
/// rewrite of existing content.
public struct FileChange: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Append `content` to an existing file (creating it with `header`
        /// if missing).
        case append
        /// Create a new file with `header` + `content`; if the path already
        /// exists the change degrades to an append.
        case create
    }

    /// Repo-relative target path.
    public let targetFile: String
    public let kind: Kind
    /// Written once when the file is first created.
    public let header: String
    /// The addition itself (markdown).
    public let content: String
    /// Which extracted items produced this change (indices into
    /// `judgment.extracted`).
    public let sourceItems: [Int]

    public var id: String { targetFile + String(sourceItems.first ?? -1) }

    public init(targetFile: String, kind: Kind, header: String, content: String, sourceItems: [Int]) {
        self.targetFile = targetFile
        self.kind = kind
        self.header = header
        self.content = content
        self.sourceItems = sourceItems
    }
}

/// Pure routing: extracted items → planned file changes, per the
/// architecture's call-type routing table.
public enum WriteBackRouter {

    /// Routes the approved subset of a judgment's extracted items.
    /// `approvedItems` are indices into `judgment.extracted`; date stamps the
    /// entries. Items sharing a target file are merged into one change.
    public static func plan(
        judgment: CallJudgment,
        approvedItems: [Int],
        date: Date = .now
    ) -> [FileChange] {
        let stamp = date.formatted(.iso8601.year().month().day())
        var byFile: [String: (kind: FileChange.Kind, header: String, parts: [String], items: [Int])] = [:]
        var order: [String] = []

        for index in approvedItems {
            guard judgment.extracted.indices.contains(index) else { continue }
            let item = judgment.extracted[index]
            let route = route(for: item, stamp: stamp)
            guard let route else { continue }
            if byFile[route.file] == nil {
                byFile[route.file] = (route.kind, route.header, [], [])
                order.append(route.file)
            }
            byFile[route.file]?.parts.append(route.entry)
            byFile[route.file]?.items.append(index)
        }
        return order.compactMap { file in
            guard let change = byFile[file] else { return nil }
            return FileChange(
                targetFile: file,
                kind: change.kind,
                header: change.header,
                content: change.parts.joined(separator: "\n"),
                sourceItems: change.items)
        }
    }

    private static func route(
        for item: CallJudgment.ExtractedItem, stamp: String
    ) -> (file: String, kind: FileChange.Kind, header: String, entry: String)? {
        // A model-suggested file wins when it is safely repo-relative.
        let suggested = item.suggestedFile.flatMap(sanitize(_:))

        switch item.kind {
        case "decision":
            return (
                suggested ?? "docs/decisions.md", .append,
                "# Decisions\n\nAppended by Saaa after each call — newest last.\n",
                "\n## \(stamp) — \(item.title)\n\n\(item.body)\n")
        case "risk":
            return (
                suggested ?? "docs/risks.md", .append,
                "# Risks\n\nAppended by Saaa after each call.\n",
                "\n## \(stamp) — \(item.title)\n\n\(item.body)\n")
        case "data_model", "api_shape":
            let slug = slugify(item.title)
            return (
                suggested ?? "docs/specs/\(stamp)-\(slug).md", .create,
                "",
                "# \(item.title)\n\n_Captured from a call on \(stamp) by Saaa._\n\n\(item.body)\n")
        case "preference":
            return (
                suggested ?? "client-preferences.md", .append,
                "# Client preferences\n\nMaintained by Saaa from call context.\n",
                "\n- **\(item.title)** (\(stamp)): \(item.body)\n")
        case "requirement":
            return (
                suggested ?? "docs/requirements.md", .append,
                "# Requirements\n\nAppended by Saaa after each call.\n",
                "\n## \(stamp) — \(item.title)\n\n\(item.body)\n")
        case "action_item":
            return (
                suggested ?? "TODO.md", .append,
                "# Action items\n",
                "- [ ] \(item.title)\(item.body.isEmpty || item.body == item.title ? "" : " — \(item.body)") _(\(stamp))_")
        default:
            return nil
        }
    }

    /// Repo-relative, traversal-free, markdown-ish paths only.
    static func sanitize(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let components = trimmed.split(separator: "/")
        guard !components.contains(".."), !components.isEmpty else { return nil }
        return trimmed
    }

    static func slugify(_ title: String) -> String {
        let slug = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-" && result.hasSuffix("-") { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "note" : String(slug.prefix(60))
    }
}
