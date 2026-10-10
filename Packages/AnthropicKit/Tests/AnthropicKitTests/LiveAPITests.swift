import Foundation
import Testing
@testable import AnthropicKit

/// Real network tests against api.anthropic.com. Off by default; the dev
/// runner enables them with `SAAA_LIVE_API=1` and a key in the environment.
/// Never prints the key.
enum LiveEnvironment {
    static var key: String { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "" }
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SAAA_LIVE_API"] == "1" && !key.isEmpty
    }
    static var client: AnthropicClient { AnthropicClient(apiKey: key) }

    static func ms(_ duration: Duration?) -> String {
        guard let duration else { return "n/a" }
        let parts = duration.components
        return "\(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000) ms"
    }
}

@Suite("Live API", .enabled(if: LiveEnvironment.enabled), .serialized)
struct LiveAPITests {

    @Test func streamsALiveAnswerFromHaiku() async throws {
        await LiveEnvironment.client.prewarm()
        let request = MessageRequest(
            model: ModelCatalog.haiku.id, maxTokens: 120,
            system: [TextBlock("You are a live meeting copilot. Answer in one short sentence.")],
            messages: [.user("Them: What's a good way to explain prompt caching to a CFO?")],
            thinking: .disabled)
        var text = ""
        var result: StreamResult?
        for try await event in LiveEnvironment.client.streamText(request) {
            switch event {
            case .text(let piece): text += piece
            case .finished(let finished): result = finished
            case .started: break
            }
        }
        print("LIVE haiku answer: ttft=\(LiveEnvironment.ms(result?.timeToFirstToken)) total=\(LiveEnvironment.ms(result?.duration)) out=\(result?.usage.outputTokens ?? 0) model=\(result?.model ?? "?")")
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result?.stopReason != nil)
        #expect((result?.usage.outputTokens ?? 0) > 0)
    }

    @Test func secondCallReadsThePromptCache() async throws {
        let nonce = UUID().uuidString
        let rules = (1...60).map {
            "Rule \($0): keep answers grounded in what was said on the call, name the speaker when it matters, and prefer specifics over generalities. (\(nonce))"
        }.joined(separator: "\n")
        func request(_ question: String) -> MessageRequest {
            MessageRequest(
                model: ModelCatalog.haiku.id, maxTokens: 40,
                system: [TextBlock(rules, cacheControl: .ephemeral)],
                messages: [.user(question)], thinking: .disabled)
        }
        var first: StreamResult?
        for try await event in LiveEnvironment.client.streamText(request("Say hi.")) {
            if case .finished(let result) = event { first = result }
        }
        var second: StreamResult?
        for try await event in LiveEnvironment.client.streamText(request("Say bye.")) {
            if case .finished(let result) = event { second = result }
        }
        print("LIVE cache: first write=\(first?.usage.cacheWrite5mTokens ?? -1) read=\(first?.usage.cacheReadTokens ?? -1); second read=\(second?.usage.cacheReadTokens ?? -1) ttft1=\(LiveEnvironment.ms(first?.timeToFirstToken)) ttft2=\(LiveEnvironment.ms(second?.timeToFirstToken))")
        #expect((first?.usage.cacheWrite5mTokens ?? 0) > 0)
        #expect((second?.usage.cacheReadTokens ?? 0) > 0)
    }

    @Test func cancellingMidStreamStopsPromptly() async throws {
        let request = MessageRequest(
            model: ModelCatalog.haiku.id, maxTokens: 900,
            messages: [.user("Write a 600-word essay about lighthouses.")], thinking: .disabled)
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            var pieces = 0
            for try await event in LiveEnvironment.client.streamText(request) {
                if case .text = event { pieces += 1 }
            }
            return pieces
        }
        try await Task.sleep(for: .milliseconds(1500))
        task.cancel()
        let pieces = (try? await task.value) ?? 0
        let elapsed = start.duration(to: clock.now)
        print("LIVE cancel: pieces before cancel=\(pieces) elapsed=\(LiveEnvironment.ms(elapsed))")
        #expect(elapsed < .seconds(4))
    }

    @Test func structuredOutputReturnsJSON() async throws {
        let schema = JSONValue.strictObject([
            "title": .string(),
            "action_items": .array(of: .string()),
        ])
        let request = MessageRequest(
            model: ModelCatalog.sonnet.id, maxTokens: 400,
            messages: [.user("""
            Transcript:
            Me: Let's ship the beta Friday.
            Them: Agreed. I'll send the release notes Thursday.
            Record the meeting.
            """)])
        let (value, result) = try await LiveEnvironment.client.structured(request, schema: schema)
        print("LIVE structured: \(LiveEnvironment.ms(result.duration)) title=\(value["title"]?.stringValue ?? "?") items=\(value["action_items"]?.stringArray.count ?? 0)")
        let items = value["action_items"]?.stringArray ?? []
        #expect(value["title"]?.stringValue?.isEmpty == false)
        #expect(items.count > 0)
    }

    @Test func lowEffortLiveAnswerOnHaiku() async throws {
        let request = MessageRequest(
            model: ModelCatalog.haiku.id, maxTokens: 120,
            system: [TextBlock("You are a live meeting copilot. One sentence.")],
            messages: [.user("Them: Can you give me a one-line pitch for a notes app?")],
            thinking: .disabled, outputConfig: OutputConfig(effort: .low))
        var result: StreamResult?
        var text = ""
        for try await event in LiveEnvironment.client.streamText(request) {
            if case .text(let piece) = event { text += piece }
            if case .finished(let finished) = event { result = finished }
        }
        print("LIVE low effort: ttft=\(LiveEnvironment.ms(result?.timeToFirstToken)) total=\(LiveEnvironment.ms(result?.duration)) chars=\(text.count)")
        #expect(!text.isEmpty)
    }

    @Test func verifiesTheKey() async throws {
        let check = try await LiveEnvironment.client.verifyKey()
        print("LIVE verify: model=\(check.model) latency=\(LiveEnvironment.ms(check.latency))")
        #expect(check.model.contains("haiku"))
    }

    @Test func badKeyIsUnauthorized() async {
        let bad = AnthropicClient(apiKey: "sk-ant-api03-invalid-key-for-saaa-tests-000000000000")
        await #expect(throws: AnthropicError.self) {
            _ = try await bad.verifyKey()
        }
    }
}
