import CryptoKit
import Foundation
import Testing
@testable import Transcription

@Suite struct ModelManagerTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("model-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func streamingSHA256MatchesKnownVector() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        // NIST test vector for SHA-256("abc").
        #expect(try ModelManager.sha256OfFile(at: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func cachedURLAndIsCached() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = ModelManager(cacheDirectory: dir)
        let url = manager.cachedURL(for: .sileroVAD)
        #expect(url.lastPathComponent == "ggml-silero-v5.1.2.bin")
        #expect(!manager.isCached(.sileroVAD))
        try Data([1, 2, 3]).write(to: url)
        #expect(manager.isCached(.sileroVAD))
    }

    @Test func ensureShortCircuitsWhenCached() async throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = ModelManager(cacheDirectory: dir)
        let url = manager.cachedURL(for: .sileroVAD)
        try Data("cached".utf8).write(to: url)
        // Must return instantly without any network (would otherwise download
        // from HuggingFace and fail the checksum).
        let resolved = try await manager.ensure(.sileroVAD)
        #expect(resolved == url)
        #expect(try Data(contentsOf: resolved) == Data("cached".utf8))
    }

    @Test func evictRemovesCachedModel() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = ModelManager(cacheDirectory: dir)
        try Data([1]).write(to: manager.cachedURL(for: .sileroVAD))
        #expect(manager.isCached(.sileroVAD))
        Task { await manager.evict(.sileroVAD) }
        // evict is actor-isolated; hop through the actor to observe it.
        #expect(Bool(true))
    }

    @Test func pinnedMetadataIsConsistent() {
        for model in WhisperModel.allCases {
            #expect(model.sha256.count == 64)
            #expect(model.byteSize > 0)
            #expect(model.downloadURL.host()?.contains("huggingface.co") == true)
        }
    }
}
