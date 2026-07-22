import Core
import Foundation

/// Renders a sealed session into a shareable artifact (issue #4): fully
/// self-contained HTML in Saaa's design language (no external assets, light
/// and dark), with Markdown as a sibling. Exports are MEANT to leave the
/// device, so what is included is explicit and raw audio never is.
public struct ExportOptions: Sendable, Equatable {
    /// Include call type, filing, and extracted context from the judgment.
    public var includeContext: Bool
    /// Apply the local deterministic redaction pass to all content.
    public var redact: Bool

    public init(includeContext: Bool = true, redact: Bool = false) {
        self.includeContext = includeContext
        self.redact = redact
    }
}

public enum TranscriptExporter {

    // MARK: - Markdown

    public static func markdown(
        archive: SessionArchive, title: String, options: ExportOptions
    ) -> String {
        let clean: (String) -> String = { options.redact ? Redactor.redact($0) : $0 }
        var lines: [String] = ["# \(clean(title))", ""]
        if let calendar = archive.calendar {
            lines.append("Meeting: \(clean(calendar.title))")
            if !calendar.attendees.isEmpty {
                lines.append("Attendees: \(clean(calendar.attendees.joined(separator: ", ")))")
            }
            lines.append("")
        }
        if options.includeContext, let judgment = archive.judgment {
            lines.append("## Context")
            lines.append("")
            lines.append("Call type: \(judgment.callType.replacingOccurrences(of: "_", with: " "))")
            if judgment.isConfident, let path = judgment.match.projectPath {
                lines.append("Filed to: \(URL(filePath: path).lastPathComponent)")
            }
            lines.append("")
            for item in judgment.extracted {
                lines.append("### \(clean(item.title)) (\(item.kind.replacingOccurrences(of: "_", with: " ")))")
                lines.append("")
                lines.append(clean(item.body))
                lines.append("")
            }
        }
        lines.append("## Transcript")
        lines.append("")
        for segment in archive.transcript.segments {
            lines.append("**\(speakerName(segment)) \(timestamp(segment.start))**  \(clean(segment.text))")
            lines.append("")
        }
        lines.append("---")
        lines.append("Exported from Saaa.")
        return lines.joined(separator: "\n")
    }

    // MARK: - HTML

    public static func html(
        archive: SessionArchive, title: String, options: ExportOptions
    ) -> String {
        let clean: (String) -> String = {
            escapeHTML(options.redact ? Redactor.redact($0) : $0)
        }
        var body = "<header><p class=\"brand\">SAAA</p><h1>\(clean(title))</h1>"
        if let calendar = archive.calendar {
            body += "<p class=\"meta\">\(clean(calendar.title))"
            if !calendar.attendees.isEmpty {
                body += " · \(clean(calendar.attendees.joined(separator: ", ")))"
            }
            body += "</p>"
        }
        body += "</header>"

        if options.includeContext, let judgment = archive.judgment {
            body += "<section><h2>Context</h2>"
            body += "<p class=\"meta\">Call type: \(clean(judgment.callType.replacingOccurrences(of: "_", with: " ")))"
            if judgment.isConfident, let path = judgment.match.projectPath {
                body += " · Filed to \(clean(URL(filePath: path).lastPathComponent))"
            }
            body += "</p>"
            for item in judgment.extracted {
                body += """
                <article class="card"><p class="kind">\(clean(item.kind.replacingOccurrences(of: "_", with: " ")))</p>\
                <h3>\(clean(item.title))</h3><p>\(clean(item.body).replacingOccurrences(of: "\n", with: "<br>"))</p></article>
                """
            }
            body += "</section>"
        }

        body += "<section><h2>Transcript</h2>"
        for segment in archive.transcript.segments {
            let me = segment.speaker == .me
            body += """
            <div class="row\(me ? " me" : "")"><span class="time">\(timestamp(segment.start))</span>\
            <span class="who">\(clean(speakerName(segment)))</span>\
            <p class="text">\(clean(segment.text))</p></div>
            """
        }
        body += "</section><footer>Exported from Saaa. Transcribed on device.</footer>"

        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(clean(title))</title>
        <style>
        :root { color-scheme: light dark;
          --base: #F4F2ED; --raised: #FFFFFF; --text: #1C1B18; --dim: #6E6A61;
          --tide: #0E7C6B; --line: rgba(28,27,24,0.14); }
        @media (prefers-color-scheme: dark) { :root {
          --base: #17181A; --raised: #1F2124; --text: #ECEAE4; --dim: #9A968C;
          --tide: #3FBFA9; --line: rgba(236,234,228,0.14); } }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: var(--base); color: var(--text);
          font: 15px/1.55 -apple-system, "Helvetica Neue", Segoe UI, sans-serif;
          max-width: 760px; margin: 0 auto; padding: 48px 24px; }
        .brand { font-size: 11px; letter-spacing: 0.2em; color: var(--dim); }
        h1 { font-size: 26px; margin: 6px 0 4px; }
        h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.12em;
          color: var(--dim); margin: 36px 0 14px; }
        .meta { color: var(--dim); font-size: 13px; }
        .card { background: var(--raised); border: 1px solid var(--line);
          border-radius: 10px; padding: 14px 16px; margin: 10px 0; }
        .card .kind { font-size: 11px; text-transform: uppercase;
          letter-spacing: 0.12em; color: var(--dim); }
        .card h3 { font-size: 15px; margin: 4px 0 6px; }
        .row { display: grid; grid-template-columns: 52px 92px 1fr;
          gap: 10px; padding: 7px 0; border-bottom: 1px solid var(--line); }
        .time { color: var(--dim); font: 12px/1.7 ui-monospace, monospace; }
        .who { font-size: 12px; font-weight: 600; text-transform: uppercase;
          letter-spacing: 0.08em; color: var(--dim); padding-top: 2px; }
        .row.me .who { color: var(--tide); }
        footer { margin-top: 44px; color: var(--dim); font-size: 12px; }
        </style></head><body>\(body)</body></html>
        """
    }

    // MARK: - Helpers

    static func speakerName(_ segment: TranscriptSegment) -> String {
        switch segment.speaker {
        case .me: "Me"
        case .them(let label): label ?? "Them"
        }
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
