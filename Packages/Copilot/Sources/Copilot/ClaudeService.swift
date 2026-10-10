import AnthropicKit
import Core
import Foundation

/// The slice of the Claude client the copilot needs: a seam for tests.
public protocol ClaudeService: Sendable {
    func streamText(_ request: MessageRequest, deadline: Duration) -> AsyncThrowingStream<TextStreamEvent, Error>
    func structured(_ request: MessageRequest, schema: JSONValue, deadline: Duration) async throws -> (value: JSONValue, result: StreamResult)
    func prewarm() async
}

extension AnthropicClient: ClaudeService {}

extension UsageRecord {
    /// Ledger entry for one finished request, priced from the catalog.
    public init(role: ModelRole, result: StreamResult) {
        let usage = result.usage
        self.init(
            role: role.rawValue,
            model: result.model,
            requests: 1,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWrite5mTokens + usage.cacheWrite1hTokens,
            costUSD: ModelCatalog.cost(of: usage, modelID: result.model))
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
