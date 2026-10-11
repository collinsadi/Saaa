import Core
import Foundation

/// Renders a session for leaving the Mac: Markdown or a self-contained HTML
/// page (light and dark, no external assets). What is included is exactly
/// what the options say; audio never is.
public enum SessionExporter {

    public struct Options: Sendable, Equatable {
        public var includeTranscript: Bool
        public var includeCopilotThread: Bool
        /// Local deterministic redaction of emails, long numbers and amounts.
        public var redact: Bool

        public init(includeTranscript: Bool = true, includeCopilotThread: Bool = false, redact: Bool = false) {
            self.includeTranscript = includeTranscript
            self.includeCopilotThread = includeCopilotThread
            self.redact = redact
        }
    }

    public static func markdown(_ record: SessionRecord, options: Options = Options()) -> String {
        var text = record.markdown(includeTranscript: false)
        if options.includeCopilotThread {
            let useful = record.thread.filter { $0.failure == nil && !$0.response.isEmpty }
            if !useful.isEmpty {
                text += "\n## Copilot during the call\n\n"
                text += useful.map { "**\($0.title)** [\(CallTime.stamp($0.callTime))]\n\($0.response)" }
                    .joined(separator: "\n\n") + "\n"
            }
        }
        if options.includeTranscript, !record.transcript.segments.isEmpty {
            text += "\n## Transcript\n\n"
            text += record.transcript.segments.map {
                "**\(speaker($0))** [\(CallTime.stamp($0.start))] \($0.text)"
            }.joined(separator: "\n\n") + "\n"
        }
        text += "\n---\nExported from Saaa\n"
        return options.redact ? Redactor.redact(text) : text
    }

    public static func html(_ record: SessionRecord, options: Options = Options()) -> String {
        let clean: (String) -> String = { escape(options.redact ? Redactor.redact($0) : $0) }
        var body = "<header><p class=\"brand\">Saaa<span>\(clean(record.playbookName))</span></p>"
        body += "<h1>\(clean(record.displayTitle))</h1>"
        var meta = [record.startedAt.formatted(date: .complete, time: .shortened)]
        if record.duration > 0 { meta.append("\(max(1, Int((record.duration / 60).rounded()))) min") }
        if !record.context.participants.isEmpty { meta.append(record.context.participants) }
        body += "<p class=\"meta\">\(clean(meta.joined(separator: " · ")))</p></header>"

        if let summary = record.summary {
            if !summary.tldr.isEmpty {
                body += "<section class=\"tldr\"><p>\(clean(summary.tldr))</p></section>"
            }
            func list(_ title: String, _ items: [String]) {
                guard !items.isEmpty else { return }
                body += "<section><h2>\(clean(title))</h2><ul>"
                body += items.map { "<li>\(clean($0))</li>" }.joined()
                body += "</ul></section>"
            }
            list("Key points", summary.keyPoints)
            list("Decisions", summary.decisions)
            if !summary.actionItems.isEmpty {
                body += "<section><h2>Action items</h2><ul class=\"actions\">"
                for item in summary.actionItems {
                    var tags: [String] = []
                    if let owner = item.owner { tags.append(owner) }
                    if let due = item.due { tags.append("due \(due)") }
                    let tag = tags.isEmpty ? "" : " <span class=\"tag\">\(clean(tags.joined(separator: " · ")))</span>"
                    body += "<li class=\"\(item.done ? "done" : "")\">\(clean(item.text))\(tag)</li>"
                }
                body += "</ul></section>"
            }
            list("Open questions", summary.openQuestions)
            for section in summary.sections { list(section.title, section.bullets) }
            // Coaching feedback stays out of exports; the checklist goes in.
            if let checklist = summary.checklist {
                list("Checklist", checklist.map { result in
                    (result.covered ? "✓ " : "○ ") + result.item + (result.evidence.isEmpty ? "" : ": \(result.evidence)")
                })
            }
            if let email = summary.followUpEmail {
                body += "<section><h2>Follow-up email draft</h2><pre>\(clean(email))</pre></section>"
            }
        }
        if options.includeCopilotThread {
            let useful = record.thread.filter { $0.failure == nil && !$0.response.isEmpty }
            if !useful.isEmpty {
                body += "<section><h2>Copilot during the call</h2>"
                for exchange in useful {
                    body += "<div class=\"assist\"><p class=\"who\">\(clean(exchange.title)) · \(CallTime.stamp(exchange.callTime))</p>"
                    body += "<p>\(clean(exchange.response).replacingOccurrences(of: "\n", with: "<br>"))</p></div>"
                }
                body += "</section>"
            }
        }
        if options.includeTranscript, !record.transcript.segments.isEmpty {
            body += "<section><h2>Transcript</h2>"
            for segment in record.transcript.segments {
                let me = segment.speaker == .me
                body += "<div class=\"line\(me ? " me" : "")\"><span class=\"time\">\(CallTime.stamp(segment.start))</span>"
                body += "<span class=\"who\">\(clean(speaker(segment)))</span><p>\(clean(segment.text))</p></div>"
            }
            body += "</section>"
        }
        body += "<footer>Exported from Saaa · transcribed on device · renders offline</footer>"
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(clean(record.displayTitle))</title>
        <style>
        :root { color-scheme: light dark; --bg: #F4F5F6; --card: #FFFFFF; --text: #16191C; --dim: #5C636A;
          --line: #DADDE0; --tide: #1F5B74; --ember: #BF5A00; }
        @media (prefers-color-scheme: dark) { :root { --bg: #111315; --card: #1A1D20; --text: #E9EBED;
          --dim: #99A0A7; --line: #2B2F34; --tide: #96CFE5; --ember: #FF9F0A; } }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { background: var(--bg); color: var(--text); font: 15px/1.6 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
          max-width: 760px; margin: 0 auto; padding: 48px 24px 64px; }
        .brand { font-weight: 600; display: flex; gap: 10px; align-items: baseline; }
        .brand span { font: 500 11px/1 ui-monospace, monospace; letter-spacing: .12em; text-transform: uppercase; color: var(--dim); }
        h1 { font-size: 26px; line-height: 1.25; margin: 14px 0 6px; letter-spacing: -0.01em; }
        .meta { color: var(--dim); font-size: 13px; }
        section { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px 20px; margin-top: 16px; }
        section.tldr { border-color: transparent; background: linear-gradient(135deg, rgba(44,110,138,.12), rgba(191,90,0,.08)); font-size: 16px; }
        h2 { font: 600 11px/1 ui-monospace, monospace; letter-spacing: .14em; text-transform: uppercase; color: var(--dim); margin-bottom: 10px; }
        ul { padding-left: 20px; } li { margin: 4px 0; }
        ul.actions { list-style: none; padding-left: 0; }
        ul.actions li::before { content: "○"; color: var(--tide); margin-right: 10px; }
        ul.actions li.done::before { content: "●"; } ul.actions li.done { color: var(--dim); text-decoration: line-through; }
        .tag { color: var(--dim); font-size: 13px; margin-left: 6px; }
        pre { white-space: pre-wrap; font: inherit; }
        .assist { padding: 8px 0; border-bottom: 1px solid var(--line); } .assist:last-child { border: 0; }
        .who { font: 500 11px/1.8 ui-monospace, monospace; letter-spacing: .1em; text-transform: uppercase; color: var(--dim); }
        .line { display: grid; grid-template-columns: 52px 64px 1fr; gap: 10px; padding: 6px 0; border-bottom: 1px solid var(--line); }
        .line:last-child { border: 0; } .line.me .who { color: var(--tide); }
        .time { color: var(--dim); font: 12px/1.9 ui-monospace, monospace; }
        footer { margin-top: 32px; color: var(--dim); font: 11px/1.6 ui-monospace, monospace; text-align: center; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// A filename-safe version of the title.
    public static func fileName(for record: SessionRecord, extension ext: String) -> String {
        let date = SessionLibrary.folderStamp(record.startedAt).prefix(8)
        let safe = record.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(date) \(safe.prefix(80)).\(ext)"
    }

    static func speaker(_ segment: TranscriptSegment) -> String {
        switch segment.speaker {
        case .me: "Me"
        case .them(let label): label ?? "Them"
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
