import Foundation

/// This Mac's connection to a Saaa relay: the server's address and a device
/// access token. The Anthropic key itself never touches the Mac's disk; it
/// lives sealed on the relay, which adds it to each request.
public struct RelayConnection: Codable, Sendable, Equatable {
    public var server: URL
    public var token: String
    public var accountID: String
    /// `sk-ant-…a1B2`, for display.
    public var keyHint: String
    public var connectedAt: Date

    public init(server: URL, token: String, accountID: String, keyHint: String, connectedAt: Date = .now) {
        self.server = server
        self.token = token
        self.accountID = accountID
        self.keyHint = keyHint
        self.connectedAt = connectedAt
    }
}

/// Keeps the ``RelayConnection`` in a small file only this user can read
/// (mode 0600), so using Claude never raises a Keychain prompt.
public struct RelayConnectionStore: Sendable {

    public static let shared = RelayConnectionStore(
        url: URL.applicationSupportDirectory.appending(path: "Saaa/connection.json"))

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public enum StoreError: Error, Equatable {
        case writeFailed
    }

    public func load() -> RelayConnection? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(RelayConnection.self, from: data)
    }

    public var isConnected: Bool {
        guard let connection = load() else { return false }
        return !connection.token.isEmpty
    }

    /// Writes atomically: a 0600 temp file renamed over the old one.
    public func save(_ connection: RelayConnection) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(connection)
        let temp = folder.appending(path: ".connection-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.writeFailed
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw StoreError.writeFailed
        }
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Claude API key shape checks for setup screens.
public enum ClaudeAPIKey {
    /// Anthropic keys start with `sk-ant-` and are long.
    public static func looksValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count >= 40 && !trimmed.contains(" ")
    }

    /// `sk-ant-…a1B2`: safe to display.
    public static func redacted(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return "••••" }
        return "sk-ant-…" + trimmed.suffix(4)
    }
}

/// The Saaa relay's account API: connect a key, check it, replace it, sign
/// this Mac out, or delete the key from the server.
public struct SaaaRelay: Sendable {

    /// The relay this build ships with, set when the app is packaged
    /// (`SaaaRelayURL` in Info.plist); nil means the user enters one.
    public static var defaultServer: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "SaaaRelayURL") as? String,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// Stands in when nothing is configured; requests fail before using it.
    static let unconfigured = URL(string: "https://relay.invalid")!

    public struct Account: Sendable, Equatable, Decodable {
        public var id: String
        public var keyHint: String
        public var devices: Int
        public var createdAt: Date?
        public var updatedAt: Date?
    }

    public struct Registration: Sendable, Equatable {
        public var connection: RelayConnection
        public var account: Account
        /// The key was already on the server; this Mac joined that account.
        public var joinedExisting: Bool
        /// How long Anthropic took to confirm the key, as seen by the server.
        public var verifiedIn: Duration
    }

    public let server: URL
    private let transport: any HTTPTransport

    public init(server: URL, transport: any HTTPTransport = URLSessionTransport.shared) {
        self.server = server
        self.transport = transport
    }

    /// Sends the key to the relay once: it checks it with Anthropic, seals it
    /// and returns this device's token.
    public func register(apiKey: String, label: String) async throws -> Registration {
        struct Body: Encodable {
            let api_key: String
            let label: String
        }
        struct Reply: Decodable {
            let token: String
            let account: Account
            let joinedExisting: Bool
            let verifiedMs: Int
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply: Reply = try await call("POST", "v1/register", token: nil, body: Body(api_key: key, label: label))
        let connection = RelayConnection(
            server: server, token: reply.token, accountID: reply.account.id, keyHint: reply.account.keyHint)
        return Registration(
            connection: connection, account: reply.account, joinedExisting: reply.joinedExisting,
            verifiedIn: .milliseconds(reply.verifiedMs))
    }

    public func account(token: String) async throws -> Account {
        try await call("GET", "v1/account", token: token, body: Optional<String>.none)
    }

    public func replaceKey(token: String, apiKey: String) async throws -> Account {
        struct Body: Encodable { let api_key: String }
        return try await call(
            "PUT", "v1/account/key", token: token,
            body: Body(api_key: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Signs this Mac out; the key stays on the server for other devices.
    public func signOut(token: String) async throws {
        _ = try await raw("DELETE", "v1/token", token: token, body: Optional<String>.none)
    }

    /// Deletes the key from the server and signs every device out.
    public func deleteAccount(token: String) async throws {
        _ = try await raw("DELETE", "v1/account", token: token, body: Optional<String>.none)
    }

    // MARK: - Internals

    private func call<Body: Encodable, Reply: Decodable>(
        _ method: String, _ path: String, token: String?, body: Body?
    ) async throws -> Reply {
        let text = try await raw(method, path, token: token, body: body)
        do {
            return try Self.decoder.decode(Reply.self, from: Data(text.utf8))
        } catch {
            throw AnthropicError.malformed("the Saaa server sent an unexpected reply")
        }
    }

    private func raw<Body: Encodable>(_ method: String, _ path: String, token: String?, body: Body?) async throws -> String {
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let transport = self.transport
        let finalRequest = request
        do {
            return try await AnthropicClient.withDeadline(.seconds(30)) {
                try await AnthropicClient.collect(transport.send(finalRequest))
            }
        } catch {
            throw AnthropicClient.normalize(error)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date"))
        }
        return decoder
    }()
}
