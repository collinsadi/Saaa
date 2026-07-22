import ClaudeBridge
import Core
import Foundation
import Testing
@testable import Persistence

@Suite struct TranscriptExporterTests {

    private var archive: SessionArchive {
        SessionArchive(
            transcript: Transcript(
                segments: [
                    TranscriptSegment(
                        speaker: .me, start: 0, end: 2,
                        text: "We ship <Friday> at bob@acme.co", confidence: 0.9),
                    TranscriptSegment(
                        speaker: .them(label: "Jane"), start: 2, end: 65,
                        text: "Agreed & done", confidence: 0.9),
                ],
                language: "en"),
            calendar: CalendarContext(title: "Acme sync", attendees: ["Jane"]),
            matches: [],
            judgment: CallJudgment(
                match: .init(
                    projectPath: "/p/acme", alternates: [],
                    confidence: 0.9, reasoning: "clear"),
                callType: "technical",
                extracted: [.init(
                    kind: "decision", title: "Ship Friday",
                    body: "Rationale here", suggestedFile: nil)]))
    }

    @Test func htmlIsSelfContainedAndEscaped() {
        let html = TranscriptExporter.html(
            archive: archive, title: "Acme call", options: ExportOptions())
        #expect(html.contains("&lt;Friday&gt;"))
        #expect(html.contains("Jane"))
        #expect(html.contains("01:05") == false) // them ends at 65 but starts 00:02
        #expect(html.contains("00:02"))
        #expect(html.contains("prefers-color-scheme"))
        #expect(!html.contains("http://") && !html.contains("https://"))
        #expect(html.contains("Ship Friday"))
        #expect(html.contains("Exported from Saaa"))
    }

    @Test func contextSectionIsOptional() {
        let bare = TranscriptExporter.html(
            archive: archive, title: "t",
            options: ExportOptions(includeContext: false))
        #expect(!bare.contains("Ship Friday"))
        #expect(bare.contains("Agreed"))
    }

    @Test func redactionAppliesEverywhere() {
        let markdown = TranscriptExporter.markdown(
            archive: archive, title: "t",
            options: ExportOptions(redact: true))
        #expect(!markdown.contains("bob@acme.co"))
        #expect(markdown.contains("[email]"))
    }

    @Test func markdownCarriesSpeakersAndTimestamps() {
        let markdown = TranscriptExporter.markdown(
            archive: archive, title: "Acme call", options: ExportOptions())
        #expect(markdown.contains("# Acme call"))
        #expect(markdown.contains("**Me 00:00**"))
        #expect(markdown.contains("**Jane 00:02**"))
        #expect(markdown.contains("Filed to: acme"))
    }
}
