import Core
import Foundation

/// One-time migration of the pre-rebuild Prompts store (`prompts.enc`): a
/// global Live Assist prompt and global vocabulary become a custom playbook,
/// so nothing the user wrote is lost.
public enum LegacyPrompts {

    public static let migratedKey = "migratedLegacyPrompts"

    /// Reads the old store. Returns nil when there is nothing to carry over.
    public static func playbook(from root: URL = PersistenceModule.defaultRoot, encryption: EncryptionService) -> Playbook? {
        let url = root.appendingPathComponent("prompts.enc")
        guard let data = try? encryption.decrypt(Data(contentsOf: url)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else { return nil }
        func globalText(_ kind: String) -> String? {
            entries.first { entry in
                (entry["kind"] as? String) == kind && (entry["scope"] as? [String: Any])?["global"] != nil
            }?["text"] as? String
        }
        let instructions = globalText("live_assist")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let vocabulary = (globalText("vocabulary") ?? "")
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !instructions.isEmpty || !vocabulary.isEmpty else { return nil }
        var playbook = Playbook.general.duplicated(named: "My Live Assist")
        if !instructions.isEmpty {
            playbook.instructions = instructions
        }
        playbook.vocabulary = vocabulary
        playbook.tagline = "Carried over from your earlier setup"
        return playbook
    }
}
