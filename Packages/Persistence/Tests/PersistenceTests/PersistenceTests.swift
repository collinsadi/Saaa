import CryptoKit
import Core
import Foundation
import Testing
@testable import Persistence

func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("saaa-persist-\(UUID().uuidString)", isDirectory: true)
}

let testKey = EncryptionService(key: SymmetricKey(size: .bits256))

func sampleRecord(title: String = "Acme renewal", minutesAgo: Double = 10) -> SessionRecord {
    SessionRecord(
        startedAt: Date().addingTimeInterval(-minutesAgo * 60),
        duration: 1_500,
        title: title,
        playbookID: Playbook.sales.id,
        playbookName: Playbook.sales.name,
        context: SessionContext(title: title, participants: "Dana Lee"),
        transcript: Transcript(segments: [
            TranscriptSegment(speaker: .them(label: nil), start: 1, end: 3, text: "How does SSO pricing work?", confidence: 1),
            TranscriptSegment(speaker: .me, start: 4, end: 7, text: "It's included on the business plan.", confidence: 1),
        ], language: "en"),
        thread: [CopilotExchange(kind: .action, title: "Answer", response: "Say: SSO is included.", callTime: 3)],
        summary: MeetingSummary(title: "Acme: SSO included", tldr: "They'll trial the business plan.",
                                actionItems: [.init(text: "Send the trial link", owner: "Me")]),
        usage: UsageLedger(records: [UsageRecord(role: "live", model: "claude-haiku-5-5", costUSD: 0.002)]))
}

@Suite struct SessionLibraryTests {

    @Test func savesListsReadsAndDeletesEncrypted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(root: root, encryption: testKey)
        let record = sampleRecord()
        let folder = try await library.makeFolder(startedAt: record.startedAt)
        try await library.save(record, folder: folder.name)

        // Content is sealed: no plaintext on disk.
        let raw = try Data(contentsOf: folder.url.appendingPathComponent("session.enc"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("SSO"))
        let index = try Data(contentsOf: root.appendingPathComponent("library.enc"))
        #expect(!String(decoding: index, as: UTF8.self).contains("Acme"))

        let entries = await library.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Acme: SSO included")
        #expect(entries.first?.openActionItems == 1)
        #expect(try await library.record(record.id) == record)

        // A fresh actor reads the same index from disk.
        let reopened = SessionLibrary(root: root, encryption: testKey)
        #expect(await reopened.entries().count == 1)

        try await library.delete(record.id)
        #expect(await library.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func searchMatchesIndexThenDeepContent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(root: root, encryption: testKey)
        for (index, title) in ["Acme renewal", "Weekly standup"].enumerated() {
            let record = sampleRecord(title: title, minutesAgo: Double(index * 60))
            var copy = record
            if index == 1 { copy.summary = nil; copy.transcript.segments = [] }
            let folder = try await library.makeFolder(startedAt: copy.startedAt)
            try await library.save(copy, folder: folder.name)
        }
        #expect(await library.search("standup").count == 1)
        #expect(await library.search("included on").count == 1)  // transcript text only
        #expect(await library.search("included on", deep: false).isEmpty)
        #expect(await library.search("").count == 2)
        #expect(await library.monthlyCost() > 0)
    }

    @Test func foldersAreUniquePerSecond() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(root: root, encryption: testKey)
        let date = Date()
        let first = try await library.makeFolder(startedAt: date)
        let second = try await library.makeFolder(startedAt: date)
        #expect(first.name != second.name)
        let imported = try await library.makeFolder(startedAt: date, suffix: "import")
        #expect(imported.name.hasSuffix("-import"))
    }

    @Test func adoptsPreRebuildArchives() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Sessions/20260722-143012", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The old archive shape: transcript, calendar, matches, judgment, notes, assistThread.
        let legacyJSON = """
        {"transcript":{"segments":[{"speaker":{"them":{}},"start":2,"end":5,"text":"Can we ship Friday?","confidence":0.9},
        {"speaker":{"me":{}},"start":6,"end":8,"text":"Yes.","confidence":0.9}],"language":"en"},
        "calendar":{"title":"Release sync","attendees":["Sam"]},"matches":[],"notes":[],
        "assistThread":[{"role":"answer","mode":"Assist","text":"Confirm Friday.","at":0}]}
        """
        try testKey.encrypt(Data(legacyJSON.utf8)).write(to: folder.appendingPathComponent("session.enc"))
        let library = SessionLibrary(root: root, encryption: testKey)
        #expect(await library.adoptUnindexedSessions() == 1)
        #expect(await library.adoptUnindexedSessions() == 0)
        let entry = try #require(await library.entries().first)
        #expect(entry.title == "Release sync")
        #expect(entry.source == .legacy)
        let record = try await library.record(entry.id)
        #expect(record.transcript.segments.count == 2)
        #expect(record.thread.first?.response == "Confirm Friday.")
        #expect(record.duration == 8)
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.year, from: record.startedAt) == 2026)
    }
}

@Suite struct PlaybookStoreTests {

    @Test func editsBuiltInsAndKeepsCustomOnes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybookStore(encryption: testKey, root: root)
        var library = store.load()
        #expect(library.all.count == Playbook.builtIns.count)
        var sales = try #require(library.playbook(id: Playbook.sales.id))
        sales.vocabulary = ["Northwind"]
        library.upsert(sales)
        let custom = Playbook.general.duplicated(named: "Board meeting")
        library.upsert(custom)
        library.defaultID = custom.id
        try store.save(library)

        let reloaded = store.load()
        #expect(reloaded.all.count == Playbook.builtIns.count + 1)
        #expect(reloaded.playbook(id: Playbook.sales.id)?.vocabulary == ["Northwind"])
        #expect(reloaded.isEdited(Playbook.sales.id))
        #expect(reloaded.defaultPlaybook.name == "Board meeting")

        var reset = reloaded
        reset.remove(id: Playbook.sales.id)
        #expect(reset.playbook(id: Playbook.sales.id)?.vocabulary == [])
        reset.remove(id: custom.id)
        #expect(reset.defaultID == Playbook.generalID)
    }

    @Test func legacyLiveAssistPromptBecomesAPlaybook() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = """
        {"entries":[{"kind":"live_assist","scope":{"global":{}},"text":"I support enterprise customers of Acme."},
        {"kind":"vocabulary","scope":{"global":{}},"text":"Okta, Northwind\\nSCIM"},
        {"kind":"filing","scope":{"nextCall":{}},"text":"ignored"}]}
        """
        try testKey.encrypt(Data(legacy.utf8)).write(to: root.appendingPathComponent("prompts.enc"))
        let playbook = try #require(LegacyPrompts.playbook(from: root, encryption: testKey))
        #expect(playbook.instructions == "I support enterprise customers of Acme.")
        #expect(playbook.vocabulary == ["Okta", "Northwind", "SCIM"])
        #expect(!playbook.isBuiltIn)
        #expect(LegacyPrompts.playbook(from: temporaryRoot(), encryption: testKey) == nil)
    }
}

@Suite struct ExporterTests {

    @Test func markdownHonorsOptions() {
        let record = sampleRecord()
        let full = SessionExporter.markdown(record, options: .init(includeTranscript: true, includeCopilotThread: true))
        #expect(full.contains("# Acme: SSO included"))
        #expect(full.contains("## Copilot during the call"))
        #expect(full.contains("**Them** [00:01] How does SSO pricing work?"))
        let lean = SessionExporter.markdown(record, options: .init(includeTranscript: false))
        #expect(!lean.contains("## Transcript"))
        #expect(!lean.contains("Copilot during the call"))
    }

    @Test func htmlEscapesAndRedacts() {
        var record = sampleRecord()
        record.transcript.segments.append(TranscriptSegment(
            speaker: .them(label: nil), start: 9, end: 10, text: "Email <dana@acme.com> about $4,000", confidence: 1))
        let html = SessionExporter.html(record, options: .init(redact: true))
        #expect(html.contains("&lt;[email]&gt;"))
        #expect(html.contains("[amount]"))
        #expect(!html.contains("dana@acme.com"))
        #expect(html.hasPrefix("<!DOCTYPE html>"))
    }

    @Test func fileNamesAreSafe() {
        var record = sampleRecord()
        record.summary?.title = "Acme / Saaa: Q3 plan?"
        let name = SessionExporter.fileName(for: record, extension: "md")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".md"))
    }
}

@Suite("Content key file")
struct ContentKeyFileTests {

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("saaa-key-\(UUID().uuidString)", isDirectory: true)
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    @Test func createsAPrivateKeyFileAndReusesIt() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try EncryptionService.loadOrCreateKey(root: root, legacy: { nil })
        let url = root.appendingPathComponent(EncryptionService.keyFileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let second = try EncryptionService.loadOrCreateKey(root: root, legacy: { Issue.record("legacy read again"); return nil })
        #expect(bytes(first) == bytes(second))
    }

    @Test func movesTheLegacyKeychainKeyOnce() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = SymmetricKey(size: .bits256)
        let loaded = try EncryptionService.loadOrCreateKey(root: root, legacy: { legacy })
        #expect(bytes(loaded) == bytes(legacy))
        let data = try Data(contentsOf: root.appendingPathComponent(EncryptionService.keyFileName))
        #expect(data == bytes(legacy))
    }

    @Test func aFailedKeychainReadNeverMintsANewKey() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: EncryptionError.keychain(-128)) {
            try EncryptionService.loadOrCreateKey(root: root, legacy: { throw EncryptionError.keychain(-128) })
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(EncryptionService.keyFileName).path))
    }

    @Test func aDamagedKeyFileIsReported() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(EncryptionService.keyFileName))
        #expect(throws: EncryptionError.keyFileCorrupt) {
            try EncryptionService.loadOrCreateKey(root: root, legacy: { nil })
        }
    }
}
