import Foundation
import Testing
@testable import AnthropicKit

@Suite struct RequestEncodingTests {

    static let cached = MessageRequest(
        model: "claude-haiku-5-5",
        maxTokens: 300,
        system: [TextBlock("rules", cacheControl: .ephemeral)],
        messages: [Message(role: .user, content: [
            .plain("chunk 1", cache: CacheControl(ttl: .oneHour)),
            .plain("tail"),
        ])],
        temperature: 0.3,
        thinking: .disabled)

    @Test func encodesSnakeCaseAndCacheControl() throws {
        let json = String(decoding: try Self.cached.encodedBody(), as: UTF8.self)
        #expect(json.contains(#""max_tokens":300"#))
        #expect(json.contains(#""cache_control":{"type":"ephemeral"}"#))
        #expect(json.contains(#""cache_control":{"ttl":"1h","type":"ephemeral"}"#))
        #expect(json.contains(#""thinking":{"type":"disabled"}"#))
        #expect(json.contains(#""stream":true"#))
        #expect(Self.cached.cacheBreakpointCount == 2)
    }

    @Test func encodingIsDeterministic() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["zeta": ["type": "string"], "alpha": ["type": "array", "items": ["type": "string"]]],
            "required": ["alpha", "zeta"],
        ]
        var request = Self.cached
        request.tools = [Tool(name: "record", description: "Record it", inputSchema: schema)]
        request.toolChoice = .tool("record")
        let first = try request.encodedBody()
        for _ in 0..<20 {
            #expect(try request.encodedBody() == first)
        }
        let json = String(decoding: first, as: UTF8.self)
        let alpha = try #require(json.range(of: "\"alpha\""))
        let zeta = try #require(json.range(of: "\"zeta\""))
        #expect(alpha.lowerBound < zeta.lowerBound)
        #expect(json.contains(#""tool_choice":{"name":"record","type":"tool"}"#))
        #expect(json.contains(#""input_schema""#))
    }

    @Test func nonStreamingOmitsTheFlagAndEmptySystem() throws {
        var request = MessageRequest(model: "m", maxTokens: 1, messages: [.user("x")])
        request.stream = false
        let json = String(decoding: try request.encodedBody(), as: UTF8.self)
        #expect(!json.contains("stream"))
        #expect(!json.contains("system"))
    }

    @Test func jsonValueRoundTripsAndEncodesIntegersCleanly() throws {
        let value: JSONValue = ["n": 3, "f": 1.5, "b": true, "s": "x", "a": [1, 2], "z": nil]
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"n\":3"))
        #expect(!text.contains("3.0"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }
}

@Suite struct ErrorMappingTests {

    @Test func statusesMapToTypedErrors() {
        let body = #"{"type":"error","error":{"type":"not_found_error","message":"model: nope"}}"#
        #expect(AnthropicError.from(status: 404, body: body, headers: [:]) == .invalidRequest("model: nope"))
        #expect(AnthropicError.from(status: 403, body: body, headers: [:]) == .permissionDenied("model: nope"))
        #expect(AnthropicError.from(status: 500, body: "", headers: [:]).isRetryable)
        #expect(AnthropicError.from(status: 529, body: "", headers: [:]) == .overloaded)
        #expect(AnthropicError.from(status: 429, body: "", headers: ["Retry-After": " 12 "]) == .rateLimited(retryAfter: 12))
        #expect(!AnthropicError.unauthorized("x").isRetryable)
    }

    @Test func userMessagesNeverEchoTheKey() {
        let errors: [AnthropicError] = [
            .missingAPIKey, .unauthorized("bad"), .rateLimited(retryAfter: 3), .overloaded, .timedOut,
            .network("offline"),
        ]
        for error in errors {
            #expect(!error.userMessage.contains("sk-ant"))
            #expect(!error.userMessage.isEmpty)
        }
    }
}

@Suite struct UsageAndPricingTests {

    @Test func haikuCostIncludesCacheTraffic() {
        let usage = TokenUsage(
            inputTokens: 500, outputTokens: 150, cacheReadTokens: 9_000, cacheWrite5mTokens: 300)
        let cost = ModelCatalog.haiku.pricing.cost(of: usage)
        // 500*0.10 + 150*0.50 + 9000*0.01 + 300*0.125 = 252.5 per MTok-unit
        #expect(abs(cost - 0.0002525) < 1e-9)
    }

    @Test func haikuLongContextBillsEverythingHigher() {
        let usage = TokenUsage(inputTokens: 120_000, outputTokens: 1_000)
        let cost = ModelCatalog.haiku.pricing.cost(of: usage)
        #expect(abs(cost - (120_000 * 0.50 + 1_000 * 2.50) / 1_000_000) < 1e-9)
    }

    @Test func unknownModelsPriceAsSonnet() {
        let usage = TokenUsage(inputTokens: 1_000_000)
        #expect(ModelCatalog.cost(of: usage, modelID: "claude-future-9") == 2)
    }

    @Test func storedShapeRoundTrips() throws {
        let usage = TokenUsage(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWrite5mTokens: 4, cacheWrite1hTokens: 5)
        let data = try JSONEncoder().encode(usage)
        #expect(try JSONDecoder().decode(TokenUsage.self, from: data) == usage)
        #expect(usage.totalInputTokens == 13)
        #expect((usage + usage).outputTokens == 4)
    }

    @Test func roleDefaultsAndOverrides() throws {
        let defaults = try #require(UserDefaults(suiteName: "saaa.tests.\(UUID().uuidString)"))
        #expect(ModelRole.live.modelID(defaults: defaults) == "claude-haiku-5-5")
        #expect(ModelRole.summary.modelID(defaults: defaults) == "claude-sonnet-5-5")
        defaults.set("claude-opus-5-5", forKey: ModelRole.summary.defaultsKey)
        #expect(ModelRole.summary.modelID(defaults: defaults) == "claude-opus-5-5")
    }
}

@Suite struct RelayConnectionTests {

    @Test func storeRoundTripsInAPrivateFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "saaa-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RelayConnectionStore(url: folder.appending(path: "connection.json"))
        #expect(store.load() == nil)
        #expect(!store.isConnected)
        let connection = RelayConnection(
            server: URL(string: "https://relay.example")!, token: "saaa_token", accountID: "acct_1",
            keyHint: "sk-ant-…WXYZ", connectedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(connection)
        #expect(store.load() == connection)
        #expect(store.isConnected)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var replaced = connection
        replaced.token = "saaa_other"
        try store.save(replaced)
        #expect(store.load()?.token == "saaa_other")
        store.delete()
        #expect(store.load() == nil)
    }

    @Test func keyShapeAndRedaction() {
        #expect(ClaudeAPIKey.redacted("sk-ant-api03-abcdefghijklmnop-WXYZ") == "sk-ant-…WXYZ")
        #expect(ClaudeAPIKey.looksValid("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!ClaudeAPIKey.looksValid("hello"))
    }

    @Test func relayClientSendsTheDeviceTokenAsBearer() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "saaa-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RelayConnectionStore(url: folder.appending(path: "connection.json"))
        try store.save(RelayConnection(
            server: URL(string: "https://relay.example")!, token: "saaa_device", accountID: "acct_1", keyHint: "x"))
        let transport = MockTransport.sse(documentedStream)
        var configuration = AnthropicClient.relay(store).configuration
        configuration.idleTimeout = 5
        let client = AnthropicClient(configuration: configuration, transport: transport) { "saaa_device" }
        for try await _ in client.streamText(sampleRequest) {}
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://relay.example/v1/messages")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer saaa_device")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func relayTokenErrorsMapToReconnect() {
        let body = #"{"type":"error","error":{"type":"relay_unauthorized","message":"unknown token"}}"#
        #expect(AnthropicError.from(status: 401, body: body, headers: [:]) == .relayUnauthorized)
        let anthropic = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(AnthropicError.from(status: 401, body: anthropic, headers: [:]) == .unauthorized("invalid x-api-key"))
    }

    @Test func registerReturnsAConnection() async throws {
        let reply = #"{"token":"saaa_new","account":{"id":"acct_9","key_hint":"sk-ant-…ABCD","devices":1,"created_at":"2026-10-11T09:00:00.123456789Z","updated_at":"2026-10-11T09:00:00Z"},"joined_existing":false,"verified_ms":412}"#
        let transport = MockTransport([.head(status: 200, headers: [:]), .line(reply)])
        let relay = SaaaRelay(server: URL(string: "https://relay.example")!, transport: transport)
        let registration = try await relay.register(apiKey: " sk-ant-api03-key ", label: "Mac")
        #expect(registration.connection.token == "saaa_new")
        #expect(registration.connection.keyHint == "sk-ant-…ABCD")
        #expect(registration.connection.server.absoluteString == "https://relay.example")
        #expect(registration.account.createdAt != nil)
        #expect(registration.verifiedIn == .milliseconds(412))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/register")
        let sent = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(sent.contains("\"api_key\":\"sk-ant-api03-key\""))
    }
}
