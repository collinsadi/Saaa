import Core
import Foundation

/// A Look from an editor extension: exact text instead of OCR, with line
/// numbers, the file's problems, the selection and the last failed
/// terminal command. Same redaction and size cap as a window read.
public enum EditorLook {

    static let messageCharacters = 300
    static let selectionCharacters = 4_000
    static let terminalLines = 60
    static let terminalCharacters = 4_000

    /// Text-like files keep whatever scene their words suggest; in code
    /// files only the editor's own problems make an error.
    static let proseLanguages: Set<String> = [
        "markdown", "plaintext", "log", "restructuredtext", "asciidoc", "latex", "org", "txt",
    ]

    /// Asks the editor window of the app in front, through the bridge. Nil
    /// when that app has no extension connected, it doesn't answer in time,
    /// or no text editor is active: the caller reads the screen instead.
    public static func snapshot(
        appPID: pid_t, bundleID: String?, windowTitle: String?,
        bridge: EditorBridge = .shared, timeout: TimeInterval = EditorBridge.requestTimeout
    ) async -> ScreenSnapshot? {
        guard let reply = await bridge.context(
            forAppPID: appPID, bundleID: bundleID, windowTitle: windowTitle, timeout: timeout) else { return nil }
        return compose(reply.context, appName: reply.app)
    }

    /// The pure end: render, redact, cap and pick the scene.
    public static func compose(
        _ context: EditorContext, appName: String, limit: Int = ScreenLook.maxCharacters, now: Date = .now
    ) -> ScreenSnapshot? {
        guard context.visible.contains(where: { !$0.text.isEmpty }) else { return nil }
        let redacted = SecretRedactor.redact(render(context))
        var text = redacted.text
        var truncated = false
        if text.count > limit {
            text = String(text.prefix(limit))
            if let cut = text.lastIndex(of: "\n") { text = String(text[..<cut]) }
            truncated = true
        }
        let title = context.file.map { SecretRedactor.redact(($0 as NSString).lastPathComponent).text }
        return ScreenSnapshot(
            appName: appName.isEmpty ? "Editor" : appName, windowTitle: title, text: text,
            scene: scene(for: context), redactions: redacted.count, truncated: truncated,
            capturedAt: now, source: .editor)
    }

    static func scene(for context: EditorContext) -> ScreenScene {
        if context.problems.contains(where: \.isError) || context.terminal != nil { return .error }
        let words = (context.visible.map(\.text) + [context.selection ?? ""]).joined(separator: "\n")
        let classified = SceneClassifier.classify(words)
        if let language = context.language?.lowercased(), proseLanguages.contains(language) { return classified }
        switch classified {
        case .error, .other: return .code
        case .problem, .code, .question: return classified
        }
    }

    /// The text that's sent: problems, selection and the failed command
    /// first, so a size cap trims code rather than the error.
    static func render(_ context: EditorContext) -> String {
        var parts: [String] = []
        var header = "File: \(context.file ?? "Untitled")"
        var details: [String] = []
        if let language = context.language, !language.isEmpty { details.append(language) }
        if let count = context.lineCount { details.append(count == 1 ? "1 line" : "\(count) lines") }
        if !details.isEmpty { header += " (\(details.joined(separator: ", ")))" }
        parts.append(header)

        if !context.problems.isEmpty {
            let lines = context.problems.map { problem -> String in
                var line = "- line \(problem.line), \(problem.severity): \(clip(oneLine(problem.message), messageCharacters))"
                let tag = [problem.source, problem.code].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                if !tag.isEmpty { line += " [\(tag)]" }
                return line
            }
            parts.append((["Problems:"] + lines).joined(separator: "\n"))
        }
        if let selection = context.selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Selected:\n" + clip(selection, selectionCharacters))
        }
        if let run = context.terminal {
            var line = "Last terminal command failed: \(oneLine(run.command))"
            if let code = run.exitCode { line += " (exit code \(code))" }
            let output = tail(run.output)
            parts.append(output.isEmpty ? line : line + "\n" + output)
        }
        let regions = context.visible + context.snippets
        let width = String(regions.map { $0.startLine + max(0, lines(of: $0).count - 1) }.max() ?? 1).count
        for (index, region) in context.visible.enumerated() where !region.text.isEmpty {
            var label = (index == 0 ? "On screen, " : "Also on screen, ") + span(region)
            if let cursor = context.cursorLine, contains(region, cursor) { label += ", cursor on line \(cursor)" }
            parts.append(label + ":\n" + numbered(region, width: width))
        }
        for region in context.snippets where !region.text.isEmpty {
            parts.append("Near a problem, \(span(region)):\n" + numbered(region, width: width))
        }
        return parts.joined(separator: "\n\n")
    }

    /// A region's lines: its text is the lines joined with "\n" and no
    /// terminator, so a trailing "\n" is a blank last line, not an ending.
    static func lines(of region: EditorContext.Region) -> [Substring] {
        region.text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    static func span(_ region: EditorContext.Region) -> String {
        let last = region.startLine + max(0, lines(of: region).count - 1)
        return last == region.startLine ? "line \(region.startLine)" : "lines \(region.startLine) to \(last)"
    }

    static func contains(_ region: EditorContext.Region, _ line: Int) -> Bool {
        line >= region.startLine && line < region.startLine + lines(of: region).count
    }

    static func numbered(_ region: EditorContext.Region, width: Int) -> String {
        lines(of: region).enumerated().map { offset, line in
            let number = String(region.startLine + offset)
            return String(repeating: " ", count: max(0, width - number.count)) + number + "  " + line
        }
        .joined(separator: "\n")
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func tail(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept = trimmed.split(separator: "\n", omittingEmptySubsequences: false).suffix(terminalLines).joined(separator: "\n")
        if kept.count > terminalCharacters {
            kept = String(kept.suffix(terminalCharacters))
            if let firstBreak = kept.firstIndex(of: "\n") { kept = String(kept[kept.index(after: firstBreak)...]) }
        }
        return kept
    }
}
