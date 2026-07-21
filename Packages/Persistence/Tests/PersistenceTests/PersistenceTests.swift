import Core
import CryptoKit
import Foundation
import Testing
@testable import Persistence

@Test func moduleLinksAndReportsIdentity() {
    #expect(PersistenceModule.name == "Persistence")
}

@Suite struct EncryptionTests {

    private let service = EncryptionService(key: SymmetricKey(size: .bits256))

    @Test func roundTripsData() throws {
        let plaintext = Data("the call content".utf8)
        let sealed = try service.encrypt(plaintext)
        #expect(sealed != plaintext)
        #expect(try service.decrypt(sealed) == plaintext)
    }

    @Test func tamperingIsDetected() throws {
        var sealed = try service.encrypt(Data("secret".utf8))
        sealed[sealed.count - 3] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try service.decrypt(sealed)
        }
    }

    @Test func wrongKeyFails() throws {
        let sealed = try service.encrypt(Data("secret".utf8))
        let other = EncryptionService(key: SymmetricKey(size: .bits256))
        #expect(throws: (any Error).self) {
            _ = try other.decrypt(sealed)
        }
    }

    @Test func codableFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = SessionArchive(
            transcript: Transcript(
                segments: [TranscriptSegment(speaker: .me, start: 0, end: 1, text: "Hi", confidence: 0.9)],
                language: "en"),
            calendar: CalendarContext(title: "Sync", attendees: ["a@b.co"]),
            matches: [], judgment: nil, notes: ["written"])
        try service.encrypt(archive, to: url)
        // On-disk bytes must not contain the plaintext.
        let raw = try Data(contentsOf: url)
        #expect(!String(decoding: raw, as: UTF8.self).contains("Sync"))
        let decoded = try service.decrypt(SessionArchive.self, from: url)
        #expect(decoded.transcript == archive.transcript)
        #expect(decoded.calendar == archive.calendar)
        #expect(decoded.notes == ["written"])
    }
}

@Suite struct SessionStoreTests {

    private func makeStore() throws -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        return (try SessionStore(directory: dir), dir)
    }

    private func row(_ started: Date, project: String? = nil) -> SessionStore.Row {
        .init(id: UUID(), startedAt: started, duration: 42,
              directoryPath: "/tmp/x", projectPath: project,
              confidence: project == nil ? nil : 0.9,
              callType: "technical", audioRetained: false, status: "review")
    }

    @Test func insertListNewestFirst() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.insert(row(Date(timeIntervalSince1970: 100)))
        try await store.insert(row(Date(timeIntervalSince1970: 300), project: "/p/saaa"))
        try await store.insert(row(Date(timeIntervalSince1970: 200)))
        let all = try await store.all()
        #expect(all.count == 3)
        #expect(all[0].projectPath == "/p/saaa")
        #expect(all.map(\.startedAt.timeIntervalSince1970) == [300, 200, 100])
    }

    @Test func statusUpdateAndDelete() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = row(.now)
        try await store.insert(record)
        try await store.updateStatus(id: record.id, status: "done")
        #expect(try await store.all().first?.status == "done")
        try await store.delete(id: record.id)
        #expect(try await store.all().isEmpty)
    }
}
