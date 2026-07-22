import CryptoKit
import Foundation
import Testing
@testable import Persistence

@Suite struct FilingMemoryTests {

    private func makeMemory() -> (FilingMemory, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filing-memory-\(UUID().uuidString)")
        let memory = FilingMemory(
            encryption: EncryptionService(key: SymmetricKey(size: .bits256)),
            directory: dir)
        return (memory, dir)
    }

    @Test func meetingLinksRoundTripCaseInsensitively() {
        let (memory, dir) = makeMemory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(memory.projectPath(forMeeting: "Acme Sync") == nil)
        memory.rememberMeeting("  Acme Sync ", project: "/p/acme")
        #expect(memory.projectPath(forMeeting: "acme sync") == "/p/acme")
        // Re-learning moves the link (correction wins over history).
        memory.rememberMeeting("Acme Sync", project: "/p/acme-v2")
        #expect(memory.projectPath(forMeeting: "ACME SYNC") == "/p/acme-v2")
    }

    @Test func vectorCentroidTracksConfirmedCalls() {
        let (memory, dir) = makeMemory()
        defer { try? FileManager.default.removeItem(at: dir) }

        memory.rememberVector([1, 0], project: "/p/acme")
        memory.rememberVector([0, 1], project: "/p/acme")
        let similarities = memory.similarities(to: [1, 1])
        // Centroid is [0.5, 0.5]; cosine with [1,1] is 1.
        #expect(abs((similarities["/p/acme"] ?? 0) - 1) < 0.0001)
    }

    @Test func dimensionChangeResetsInsteadOfCorrupting() {
        let (memory, dir) = makeMemory()
        defer { try? FileManager.default.removeItem(at: dir) }

        memory.rememberVector([1, 0], project: "/p/acme")
        memory.rememberVector([1, 0, 0], project: "/p/acme")
        #expect(memory.similarities(to: [1, 0, 0])["/p/acme"] == 1)
    }

    @Test func clearForgetsEverything() {
        let (memory, dir) = makeMemory()
        defer { try? FileManager.default.removeItem(at: dir) }

        memory.rememberMeeting("Acme Sync", project: "/p/acme")
        memory.rememberVector([1, 0], project: "/p/acme")
        memory.clear()
        #expect(memory.projectPath(forMeeting: "Acme Sync") == nil)
        #expect(memory.similarities(to: [1, 0]).isEmpty)
    }

    @Test func storeIsSealedNotPlaintext() throws {
        let (memory, dir) = makeMemory()
        defer { try? FileManager.default.removeItem(at: dir) }

        memory.rememberMeeting("Secret Client Sync", project: "/p/secret")
        let data = try Data(contentsOf: dir.appendingPathComponent("filing-memory.enc"))
        #expect(!String(decoding: data, as: UTF8.self).contains("Secret Client"))
    }
}
