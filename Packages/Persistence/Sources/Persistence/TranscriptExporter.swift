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
        if options.includeContext, let thread = archive.assistThread, !thread.isEmpty {
            lines.append("## Live Assist")
            lines.append("")
            for entry in thread where entry.role != "failed" {
                let label = entry.role == "ask" ? "You asked" : (entry.mode ?? "Assist")
                lines.append("**\(label)**  \(clean(entry.text))")
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
        lines.append("Exported from Saaa. Transcribed and sealed on this Mac.")
        return lines.joined(separator: "\n")
    }

    // MARK: - HTML

    public static func html(
        archive: SessionArchive, title: String, options: ExportOptions
    ) -> String {
        let clean: (String) -> String = {
            escapeHTML(options.redact ? Redactor.redact($0) : $0)
        }
        // Inline lockup: three staggered bars + the ember dot, colors bound
        // to the stylesheet so both appearances render the brand correctly.
        let lockup = """
        <svg class="lockup" width="16" height="16" viewBox="0 0 64 64" aria-hidden="true">\
        <rect x="16" width="12" height="34" rx="6" fill="var(--text)"/>\
        <rect x="34" y="10" width="12" height="54" rx="6" fill="var(--text)"/>\
        <rect y="24" width="12" height="30" rx="6" fill="var(--text)"/>\
        <circle cx="56" cy="56" r="8" fill="var(--ember)"/></svg>
        """
        var body = "<header><p class=\"brand\">\(lockup)<span>Saaa</span><span class=\"tag\">Transcript</span></p><h1>\(clean(title))</h1>"
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

        if options.includeContext, let thread = archive.assistThread, !thread.isEmpty {
            body += "<section><h2>Live Assist</h2>"
            for entry in thread where entry.role != "failed" {
                let label = entry.role == "ask" ? "You asked" : (entry.mode ?? "Assist")
                body += """
                <div class="assist"><span class="who">\(clean(label))</span>\
                <p class="text">\(clean(entry.text).replacingOccurrences(of: "\n", with: "<br>"))</p></div>
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
        body += "</section><footer>Exported from Saaa · transcribed and sealed on this Mac · renders offline</footer>"

        // Field Instrument tokens (ColorTokens.swift): cool graphite, Tide
        // interactive, Ember reserved for the lockup dot. Solid hairlines —
        // no translucency, no warm cast, no teal.
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(clean(title))</title>
        <style>
        :root { color-scheme: light dark;
          --base: #ECEEEF; --raised: #F7F8F9; --inset: #E2E5E7;
          --text: #16191C; --secondary: #454C52; --dim: #5C636A;
          --tide: #1F5B74; --ember: #BF5A00; --line: #C6CACD; }
        @media (prefers-color-scheme: dark) { :root {
          --base: #14171A; --raised: #1D2024; --inset: #0F1114;
          --text: #E9EBED; --secondary: #B6BCC2; --dim: #99A0A7;
          --tide: #96CFE5; --ember: #FF9F0A; --line: #2B2F34; } }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: var(--base); color: var(--text);
          font: 15px/1.55 -apple-system, "Helvetica Neue", Segoe UI, sans-serif;
          max-width: 720px; margin: 0 auto; padding: 48px 24px; }
        .brand { display: flex; align-items: center; gap: 8px;
          font-size: 15px; font-weight: 600; }
        .brand .lockup { flex: none; }
        .brand .tag { margin-left: auto; font: 10px/1 ui-monospace, monospace;
          font-weight: 500; text-transform: uppercase; letter-spacing: 0.14em;
          color: var(--dim); }
        h1 { font-size: 22px; margin: 18px 0 4px; }
        h2 { font: 10px/1 ui-monospace, monospace; font-weight: 500;
          text-transform: uppercase; letter-spacing: 0.14em;
          color: var(--dim); margin: 36px 0 14px; }
        .meta { color: var(--dim); font: 12px/1.6 ui-monospace, monospace; }
        .card { background: var(--raised); border: 1px solid var(--line);
          border-radius: 8px; padding: 14px 16px; margin: 10px 0; }
        .card .kind { font: 10px/1 ui-monospace, monospace; font-weight: 500;
          text-transform: uppercase; letter-spacing: 0.14em; color: var(--dim); }
        .card h3 { font-size: 15px; margin: 6px 0 6px; }
        .card p { color: var(--secondary); }
        .row { display: grid; grid-template-columns: 52px 92px 1fr;
          gap: 10px; padding: 7px 0; border-bottom: 1px solid var(--line); }
        .time { color: var(--dim); font: 12px/1.7 ui-monospace, monospace; }
        .who { font: 10px/1.9 ui-monospace, monospace; font-weight: 500;
          text-transform: uppercase; letter-spacing: 0.14em; color: var(--dim); }
        .row.me .who { color: var(--tide); }
        .assist { padding: 7px 0; border-bottom: 1px solid var(--line); }
        .assist .text { margin-top: 2px; }
        footer { margin-top: 44px; color: var(--dim);
          font: 11px/1.6 ui-monospace, monospace; }
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
