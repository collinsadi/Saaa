import ClaudeBridge
import Foundation
import Testing
@testable import Extraction

@Test func moduleLinksAndReportsIdentity() {
    #expect(ExtractionModule.name == "Extraction")
}

private func judgment(_ items: [CallJudgment.ExtractedItem]) -> CallJudgment {
    CallJudgment(
        match: .init(projectPath: "/tmp/p", alternates: [], confidence: 0.9, reasoning: "r"),
        callType: "technical",
        extracted: items)
}

private func item(
    _ kind: String, _ title: String, body: String = "Body.", file: String? = nil
) -> CallJudgment.ExtractedItem {
    .init(kind: kind, title: title, body: body, suggestedFile: file)
}

@Suite struct RouterTests {

    @Test func routesEveryKindToItsArtifact() {
        let plan = WriteBackRouter.plan(
            judgment: judgment([
                item("decision", "Use SQLite"),
                item("data_model", "Invoice shape"),
                item("preference", "No purple"),
                item("action_item", "Send proposal"),
                item("requirement", "Offline mode"),
                item("risk", "Vendor lock-in"),
            ]),
            approvedItems: [0, 1, 2, 3, 4, 5])
        let files = plan.map(\.targetFile)
        #expect(files.contains("docs/decisions.md"))
        #expect(files.contains { $0.hasPrefix("docs/specs/") && $0.hasSuffix("invoice-shape.md") })
        #expect(files.contains("client-preferences.md"))
        #expect(files.contains("TODO.md"))
        #expect(files.contains("docs/requirements.md"))
        #expect(files.contains("docs/risks.md"))
    }

    @Test func onlyApprovedItemsAreRouted() {
        let plan = WriteBackRouter.plan(
            judgment: judgment([item("decision", "A"), item("decision", "B")]),
            approvedItems: [1])
        #expect(plan.count == 1)
        #expect(plan[0].content.contains("B"))
        #expect(!plan[0].content.contains("## A"))
        #expect(plan[0].sourceItems == [1])
    }

    @Test func sameFileItemsMerge() {
        let plan = WriteBackRouter.plan(
            judgment: judgment([item("decision", "A"), item("decision", "B")]),
            approvedItems: [0, 1])
        #expect(plan.count == 1)
        #expect(plan[0].content.contains("A") && plan[0].content.contains("B"))
        #expect(plan[0].sourceItems == [0, 1])
    }

    @Test func suggestedFileWinsWhenSafe() {
        let plan = WriteBackRouter.plan(
            judgment: judgment([item("decision", "A", file: "notes/calls.md")]),
            approvedItems: [0])
        #expect(plan[0].targetFile == "notes/calls.md")
    }

    @Test func traversalAndAbsoluteSuggestionsAreRejected() {
        #expect(WriteBackRouter.sanitize("../../etc/passwd") == nil)
        #expect(WriteBackRouter.sanitize("/etc/passwd") == nil)
        #expect(WriteBackRouter.sanitize("~/x.md") == nil)
        #expect(WriteBackRouter.sanitize("docs/ok.md") == "docs/ok.md")
        let plan = WriteBackRouter.plan(
            judgment: judgment([item("decision", "A", file: "../evil.md")]),
            approvedItems: [0])
        #expect(plan[0].targetFile == "docs/decisions.md")
    }

    @Test func slugifyIsFilenameSafe() {
        #expect(WriteBackRouter.slugify("Invoice API v2 — the (final) shape!") == "invoice-api-v2-the-final-shape")
        #expect(WriteBackRouter.slugify("???") == "note")
    }

    @Test func unknownKindIsDropped() {
        let plan = WriteBackRouter.plan(
            judgment: judgment([item("haiku", "A")]), approvedItems: [0])
        #expect(plan.isEmpty)
    }
}

@Suite struct EngineTests {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("writeback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func createsFileWithHeaderThenAppends() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = WriteBackEngine(projectRoot: root)
        let change = FileChange(
            targetFile: "docs/decisions.md", kind: .append,
            header: "# Decisions\n", content: "\n## Use SQLite\n\nBecause.\n",
            sourceItems: [0])

        let first = engine.preview(change)
        #expect(first.resultingContent.hasPrefix("# Decisions"))
        #expect(engine.apply([first]) == [.applied(targetFile: "docs/decisions.md")])

        let second = engine.preview(FileChange(
            targetFile: "docs/decisions.md", kind: .append,
            header: "# Decisions\n", content: "\n## Add VAD\n\nTrims silence.\n",
            sourceItems: [1]))
        #expect(engine.apply([second]) == [.applied(targetFile: "docs/decisions.md")])

        let text = try String(contentsOf: root.appendingPathComponent("docs/decisions.md"), encoding: .utf8)
        #expect(text.contains("Use SQLite") && text.contains("Add VAD"))
        #expect(text.components(separatedBy: "# Decisions").count == 2) // header once
    }

    @Test func conflictWhenFileChangedSinceReviewAndNothingIsWritten() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = WriteBackEngine(projectRoot: root)
        let target = root.appendingPathComponent("TODO.md")
        try "# Action items\n- [ ] old\n".write(to: target, atomically: true, encoding: .utf8)

        let change = FileChange(
            targetFile: "TODO.md", kind: .append, header: "# Action items\n",
            content: "- [ ] new thing", sourceItems: [0])
        let preview = engine.preview(change)

        // Someone edits the file between review and apply.
        try "# Action items\n- [x] old\n- [ ] rogue\n".write(to: target, atomically: true, encoding: .utf8)

        let outcomes = engine.apply([preview])
        guard case .conflict(let file, let diff) = outcomes[0] else {
            Issue.record("expected conflict, got \(outcomes[0])")
            return
        }
        #expect(file == "TODO.md")
        #expect(diff.contains("rogue"))
        // The rogue edit must remain untouched.
        let after = try String(contentsOf: target, encoding: .utf8)
        #expect(after.contains("rogue") && !after.contains("new thing"))
    }

    @Test func deletedSinceReviewIsAConflict() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = WriteBackEngine(projectRoot: root)
        let target = root.appendingPathComponent("notes.md")
        try "hello\n".write(to: target, atomically: true, encoding: .utf8)
        let preview = engine.preview(FileChange(
            targetFile: "notes.md", kind: .append, header: "", content: "more", sourceItems: [0]))
        try FileManager.default.removeItem(at: target)
        let outcomes = engine.apply([preview])
        guard case .conflict = outcomes[0] else {
            Issue.record("expected conflict, got \(outcomes[0])")
            return
        }
    }
}
