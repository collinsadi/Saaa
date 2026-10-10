import Core
import Foundation

/// The user's playbooks: edited built-ins (same id) and custom ones, plus
/// the default. Sealed with the content key: playbooks hold client names,
/// pricing and other sensitive reference material.
public struct PlaybookLibrary: Sendable, Codable, Equatable {
    /// Edited built-ins and custom playbooks.
    public var stored: [Playbook]
    public var defaultID: String

    public init(stored: [Playbook] = [], defaultID: String = Playbook.generalID) {
        self.stored = stored
        self.defaultID = defaultID
    }

    /// Built-ins (with edits applied) first, then custom playbooks.
    public var all: [Playbook] {
        let edited = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let builtIns = Playbook.builtIns.map { edited[$0.id] ?? $0 }
        let custom = stored.filter { stored in !Playbook.builtIns.contains { $0.id == stored.id } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return builtIns + custom
    }

    public func playbook(id: String) -> Playbook? {
        all.first { $0.id == id }
    }

    public var defaultPlaybook: Playbook {
        playbook(id: defaultID) ?? .general
    }

    public mutating func upsert(_ playbook: Playbook) {
        var updated = playbook
        updated.updatedAt = .now
        stored.removeAll { $0.id == playbook.id }
        stored.append(updated)
    }

    /// Deletes a custom playbook, or resets an edited built-in.
    public mutating func remove(id: String) {
        stored.removeAll { $0.id == id }
        if playbook(id: defaultID) == nil { defaultID = Playbook.generalID }
    }

    public func isEdited(_ id: String) -> Bool {
        Playbook.builtIns.contains { $0.id == id } && stored.contains { $0.id == id }
    }
}

public struct PlaybookStore: Sendable {
    private let encryption: EncryptionService
    private let url: URL

    public init(encryption: EncryptionService, root: URL = PersistenceModule.defaultRoot) {
        self.encryption = encryption
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.url = root.appendingPathComponent("playbooks.enc")
    }

    public func load() -> PlaybookLibrary {
        (try? encryption.decrypt(PlaybookLibrary.self, from: url)) ?? PlaybookLibrary()
    }

    public func save(_ library: PlaybookLibrary) throws {
        try encryption.encrypt(library, to: url)
    }
}
