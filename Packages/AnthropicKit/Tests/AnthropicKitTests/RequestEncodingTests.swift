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

@Suite struct KeychainTests {

    @Test func roundTripsAndRedacts() throws {
        let store = KeychainKeyStore(service: "dev.collinsadi.saaa.tests.\(UUID().uuidString)", account: "k")
        defer { try? store.delete() }
        #expect(store.load() == nil)
        try store.save("  sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789-WXYZ \n")
        #expect(store.load() == "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789-WXYZ")
        try store.save("sk-ant-api03-replaced-0000000000000000000000000000-ABCD")
        #expect(store.load()?.hasSuffix("ABCD") == true)
        try store.delete()
        #expect(!store.hasKey)
        #expect(KeychainKeyStore.redacted("sk-ant-api03-abcdefghijklmnop-WXYZ") == "sk-ant-…WXYZ")
        #expect(KeychainKeyStore.looksLikeAPIKey("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!KeychainKeyStore.looksLikeAPIKey("hello"))
    }
}
