import Core
import CryptoKit
import Foundation
import Testing
@testable import Persistence

@Suite struct PromptStoreTests {

    private func makeStore() -> (PromptStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-store-\(UUID().uuidString)")
        let store = PromptStore(
            encryption: EncryptionService(key: SymmetricKey(size: .bits256)),
            directory: dir)
        return (store, dir)
    }

    @Test func scopesAreIsolatedAndRoundTrip() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.set(.filing, scope: .global, text: "global rules")
        store.set(.filing, scope: .project(path: "/p/acme"), text: "acme rules")
        store.set(.filing, scope: .callType("standup"), text: "standup rules")
        store.set(.vocabulary, scope: .global, text: "Saaa, whisper")

        #expect(store.text(.filing, scope: .global) == "global rules")
        #expect(store.text(.filing, scope: .project(path: "/p/acme")) == "acme rules")
        #expect(store.text(.filing, scope: .project(path: "/p/other")) == nil)
        #expect(store.text(.vocabulary, scope: .global) == "Saaa, whisper")
        #expect(store.callTypeBlocks(.filing) == ["standup": "standup rules"])
    }

    @Test func emptyTextDeletesTheEntry() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.set(.filing, scope: .global, text: "something")
        store.set(.filing, scope: .global, text: "   \n")
        #expect(store.text(.filing, scope: .global) == nil)
    }

    @Test func nextCallIsClearedOnConsume() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.set(.filing, scope: .nextCall, text: "one time")
        store.set(.vocabulary, scope: .nextCall, text: "OneTimeTerm")
        store.set(.filing, scope: .global, text: "keep me")
        store.clearNextCall()
        #expect(store.text(.filing, scope: .nextCall) == nil)
        #expect(store.text(.vocabulary, scope: .nextCall) == nil)
        #expect(store.text(.filing, scope: .global) == "keep me")
    }

    @Test func storeIsSealedNotPlaintext() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.set(.vocabulary, scope: .global, text: "SecretClientName")
        let data = try Data(contentsOf: dir.appendingPathComponent("prompts.enc"))
        #expect(!String(decoding: data, as: UTF8.self).contains("SecretClientName"))
    }
}
