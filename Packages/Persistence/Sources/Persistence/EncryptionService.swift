import CryptoKit
import Foundation
import Security
import os

/// AES-GCM encryption for call content at rest, keyed by a per-user symmetric
/// key held in the login Keychain. Audio and transcripts never touch disk
/// unencrypted once a session is archived.
public struct EncryptionService: Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "EncryptionService")
    private static let keychainService = "dev.collinsadi.saaa.contentkey"

    private let key: SymmetricKey

    /// Loads (or creates on first use) the keychain-held key.
    public init() throws {
        self.key = try Self.loadOrCreateKey()
    }

    /// Test seam: explicit key, no keychain involved.
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

    private static func loadOrCreateKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            throw EncryptionError.keychain(status)
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrLabel as String: "Saaa call-content encryption key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: keyData,
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw EncryptionError.keychain(addStatus)
        }
        log.info("created content-encryption key in keychain")
        return newKey
    }
}

public enum EncryptionError: Error, Equatable {
    case sealFailed
    case keychain(OSStatus)
}
