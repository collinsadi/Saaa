import CryptoKit
import Foundation
import Security
import os

/// AES-GCM encryption for call content at rest. The 256-bit key lives in
/// Saaa's own folder (`content.key`, mode 0600, readable only by this macOS
/// account), so opening sessions never raises a Keychain prompt. Older
/// versions kept it in the login Keychain; it moves to the file once.
public struct EncryptionService: Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "EncryptionService")
    static let legacyKeychainService = "dev.collinsadi.saaa.contentkey"
    static let keyFileName = "content.key"

    private let key: SymmetricKey

    /// Loads the key from `root`, creating it on first use.
    public init(root: URL = PersistenceModule.defaultRoot) throws {
        self.key = try Self.loadOrCreateKey(root: root, legacy: Self.legacyKeychainKey)
    }

    /// Test seam: explicit key, nothing on disk.
    public init(key: SymmetricKey) {
        self.key = key
    }

    // MARK: - Sealing

    public func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw EncryptionError.sealFailed
        }
        return combined
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    /// Encrypts a Codable value to a file (atomic).
    public func encrypt<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try encrypt(data).write(to: url, options: .atomic)
    }

    /// Decrypts a file back into a Codable value.
    public func decrypt<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try decrypt(try Data(contentsOf: url))
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Key management

    /// The key file, else a one-time move of the legacy Keychain key, else a
    /// new key. A Keychain read that fails for any reason other than "not
    /// found" throws rather than minting a key that can't open old sessions.
    static func loadOrCreateKey(
        root: URL, legacy: () throws -> SymmetricKey?
    ) throws -> SymmetricKey {
        let url = root.appendingPathComponent(keyFileName)
        if let data = try? Data(contentsOf: url) {
            guard data.count == 32 else { throw EncryptionError.keyFileCorrupt }
            return SymmetricKey(data: data)
        }
        let key = try legacy() ?? SymmetricKey(size: .bits256)
        try writeKeyFile(key, to: url)
        log.info("content key stored in Saaa's folder")
        return key
    }

    static func writeKeyFile(_ key: SymmetricKey, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = key.withUnsafeBytes { Data($0) }
        let temp = folder.appendingPathComponent(".content-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw EncryptionError.keyFileWrite
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw EncryptionError.keyFileWrite
        }
    }

    /// Reads the key older versions created in the login Keychain.
    static func legacyKeychainKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw EncryptionError.keychain(status)
        }
    }
}

public enum EncryptionError: Error, Equatable {
    case sealFailed
    case keychain(OSStatus)
    case keyFileCorrupt
    case keyFileWrite
}
