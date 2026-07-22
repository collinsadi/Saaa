import Core
import Foundation

/// Persistence for custom prompts (issue #2). Prompts routinely carry
/// sensitive context (client names, internal jargon), so the store is
/// sealed with the same AES-GCM key as session archives and never leaves
/// this Mac.
public struct PromptStore: Sendable {

    struct Payload: Codable {
        var entries: [Entry] = []
    }

    struct Entry: Codable {
        var kind: PromptKind
        var scope: PromptScope
        var text: String
    }

    private let encryption: EncryptionService
    private let url: URL

    public init(encryption: EncryptionService, directory: URL? = nil) {
        self.encryption = encryption
        let base = directory ?? URL.applicationSupportDirectory
            .appendingPathComponent("Saaa", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("prompts.enc")
    }

    // MARK: - Access

    public func text(_ kind: PromptKind, scope: PromptScope) -> String? {
        load().entries.first { $0.kind == kind && $0.scope == scope }?.text
    }

    /// Every call-type block of one kind, keyed by call type.
    public func callTypeBlocks(_ kind: PromptKind) -> [String: String] {
        var blocks: [String: String] = [:]
        for entry in load().entries where entry.kind == kind {
            if case .callType(let type) = entry.scope {
                blocks[type] = entry.text
            }
        }
        return blocks
    }

    /// Writes a prompt; empty (after trimming) deletes the entry.
    public func set(_ kind: PromptKind, scope: PromptScope, text: String) {
        var payload = load()
        payload.entries.removeAll { $0.kind == kind && $0.scope == scope }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            payload.entries.append(Entry(kind: kind, scope: scope, text: text))
        }
        save(payload)
    }

    /// One-time prompts are consumed by the next processed call.
    public func clearNextCall() {
        var payload = load()
        payload.entries.removeAll { $0.scope == .nextCall }
        save(payload)
    }

    public func clearAll() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Store

    private func load() -> Payload {
        (try? encryption.decrypt(Payload.self, from: url)) ?? Payload()
    }

    private func save(_ payload: Payload) {
        try? encryption.encrypt(payload, to: url)
    }
}
