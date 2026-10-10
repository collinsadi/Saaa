import Foundation

/// Local encrypted storage: sealed session records, the library index,
/// playbooks, exports, and migration of pre-rebuild data.
public enum PersistenceModule {
    /// Module identity used in diagnostics and privacy-safe logs.
    public static let name = "Persistence"

    /// `~/Library/Application Support/Saaa`.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Saaa", isDirectory: true)
    }
}
