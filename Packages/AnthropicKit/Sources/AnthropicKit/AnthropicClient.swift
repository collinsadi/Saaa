import Foundation
import os

/// A text-first view of a streaming response, for live UI.
public enum TextStreamEvent: Sendable, Equatable {
    /// The response began (`message_start`).
    case started(model: String)
    /// A piece of answer text.
    case text(String)
    /// The response completed.
    case finished(StreamResult)
}

/// Outcome of one completed request.
public struct StreamResult: Sendable, Equatable {
    public var model: String
    public var stopReason: String?
    public var usage: TokenUsage
    /// Time from request start to the first text delta.
    public var timeToFirstToken: Duration?
    public var duration: Duration

    public init(
        model: String, stopReason: String?, usage: TokenUsage,
        timeToFirstToken: Duration?, duration: Duration
    ) {
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.timeToFirstToken = timeToFirstToken
        self.duration = duration
    }
}

/// Result of a live key check.
public struct KeyCheck: Sendable, Equatable {
    public var model: String
    public var latency: Duration
}

/// Claude Messages API client: SSE streaming, non-streaming, forced-tool
/// structured output, key verification. Stateless and Sendable; the key is
/// read per request so a key change applies immediately.
public struct AnthropicClient: Sendable {

    public struct Configuration: Sendable {
        public var baseURL: URL
        public var apiVersion: String
        /// Idle timeout between bytes.
        public var idleTimeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "https://api.anthropic.com")!,
            apiVersion: String = "2023-06-01",
            idleTimeout: TimeInterval = 30
        ) {
            self.baseURL = baseURL
            self.apiVersion = apiVersion
            self.idleTimeout = idleTimeout
        }
    }

    public typealias KeyProvider = @Sendable () throws -> String

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "AnthropicClient")

    private let configuration: Configuration
    private let transport: any HTTPTransport
    private let keyProvider: KeyProvider

    public init(
        configuration: Configuration = Configuration(),
        transport: any HTTPTransport = URLSessionTransport.shared,
        keyProvider: @escaping KeyProvider
    ) {
        self.configuration = configuration
        self.transport = transport
        self.keyProvider = keyProvider
    }

    /// A client with a fixed key (tests, verification of a key not yet saved).
    public init(
        apiKey: String,
        configuration: Configuration = Configuration(),
        transport: any HTTPTransport = URLSessionTransport.shared
    ) {
        self.init(configuration: configuration, transport: transport) { apiKey }
    }

    /// The app's client: the key comes from the Keychain on every request.
    public static func keychain(
        _ store: KeychainKeyStore = .shared,
        configuration: Configuration = Configuration()
    ) -> AnthropicClient {
        AnthropicClient(configuration: configuration) {
            guard let key = store.load(), !key.isEmpty else { throw AnthropicError.missingAPIKey }
            return key
        }
    }

    // MARK: - Streaming

    /// Raw event stream for a request (`stream` is forced on). Finishes after
    /// `message_stop`; throws ``AnthropicError`` (or `CancellationError`).
    public func events(
        _ request: MessageRequest,
        deadline: Duration = .seconds(90)
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request
                    request.stream = true
                    let urlRequest = try client.makeURLRequest(
                        path: "v1/messages", body: try request.encodedBody(), streaming: true)
                    let transport = client.transport
                    try await Self.withDeadline(deadline) {
                        try await Self.pump(transport.send(urlRequest), into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Text deltas plus a final ``StreamResult`` (usage, stop reason, timing).
    public func streamText(
        _ request: MessageRequest,
        deadline: Duration = .seconds(90)
    ) -> AsyncThrowingStream<TextStreamEvent, Error> {
        let events = events(request, deadline: deadline)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let start = clock.now
                var model = request.model
                var usage = TokenUsage.zero
                var stopReason: String?
                var firstToken: Duration?
                do {
                    for try await event in events {
                        switch event {
                        case .messageStart(_, let startedModel, let startUsage):
                            if !startedModel.isEmpty { model = startedModel }
                            usage = usage.merged(with: startUsage)
                            continuation.yield(.started(model: model))
                        case .textDelta(_, let text):
                            if firstToken == nil { firstToken = start.duration(to: clock.now) }
                            continuation.yield(.text(text))
                        case .messageDelta(let reason, let deltaUsage):
                            if let reason { stopReason = reason }
                            if let deltaUsage { usage = usage.merged(with: deltaUsage) }
                        case .messageStop:
                            break
                        default:
                            break
                        }
                    }
                    continuation.yield(.finished(StreamResult(
                        model: model, stopReason: stopReason, usage: usage,
                        timeToFirstToken: firstToken, duration: start.duration(to: clock.now))))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Non-streaming

    /// One complete response.
    public func send(
        _ request: MessageRequest,
        deadline: Duration = .seconds(120)
    ) async throws -> MessageResponse {
        var request = request
        request.stream = false
        do {
            let urlRequest = try makeURLRequest(
                path: "v1/messages", body: try request.encodedBody(), streaming: false)
            let transport = self.transport
            return try await Self.withDeadline(deadline) {
                let body = try await Self.collect(transport.send(urlRequest))
                do {
                    return try JSONDecoder().decode(MessageResponse.self, from: Data(body.utf8))
                } catch {
                    throw AnthropicError.malformed("response body did not decode")
                }
            }
        } catch {
            throw Self.normalize(error)
        }
    }

    /// Structured output: sets `output_config.format` to `schema` and returns
    /// the parsed JSON reply. Works on every current model (forced tool
    /// choice does not).
    public func structured(
        _ request: MessageRequest,
        schema: JSONValue,
        deadline: Duration = .seconds(120)
    ) async throws -> (value: JSONValue, result: StreamResult) {
        var request = request
        var config = request.outputConfig ?? OutputConfig()
        config.format = .jsonSchema(schema)
        request.outputConfig = config
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await send(request, deadline: deadline)
        switch response.stopReason {
        case "refusal":
            throw AnthropicError.invalidRequest("Claude declined to produce this output")
        case "max_tokens":
            throw AnthropicError.malformed("structured output was cut off by max_tokens")
        default:
            break
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let value = try? JSONValue.parse(text) else {
            throw AnthropicError.malformed("structured output was not valid JSON")
        }
        let elapsed = start.duration(to: clock.now)
        return (value, StreamResult(
            model: response.model, stopReason: response.stopReason, usage: response.usage,
            timeToFirstToken: nil, duration: elapsed))
    }

    // MARK: - Key + connection

    /// Verifies a key with a tiny request and reports round-trip latency.
    public func verifyKey(model: String = ModelCatalog.haiku.id) async throws -> KeyCheck {
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await send(MessageRequest(
            model: model, maxTokens: 8,
            messages: [.user("Reply with the single word: ready")]),
            deadline: .seconds(30))
        return KeyCheck(model: response.model, latency: start.duration(to: clock.now))
    }

    /// Opens (or reuses) the TLS + HTTP/2 connection before the first live
    /// question, so the first answer doesn't pay the handshake. Free: lists
    /// one model. Failures are ignored.
    public func prewarm() async {
        guard let urlRequest = try? makeURLRequest(
            path: "v1/models", body: nil, streaming: false, method: "GET",
            query: [URLQueryItem(name: "limit", value: "1")])
        else { return }
        _ = try? await Self.withDeadline(.seconds(10)) { [transport] in
            _ = try await Self.collect(transport.send(urlRequest))
        }
    }

    // MARK: - Internals

    func makeURLRequest(
        path: String, body: Data?, streaming: Bool,
        method: String = "POST", query: [URLQueryItem] = []
    ) throws -> URLRequest {
        let key = try keyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AnthropicError.missingAPIKey }
        var url = configuration.baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = configuration.idleTimeout
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        if body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        urlRequest.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "accept")
        urlRequest.httpBody = body
        return urlRequest
    }

    /// Reads a whole body; throws the mapped API error for non-2xx.
    static func collect(_ stream: AsyncThrowingStream<TransportEvent, Error>) async throws -> String {
        var status = 0
        var headers: [String: String] = [:]
        var lines: [String] = []
        for try await event in stream {
            switch event {
            case .head(let code, let fields):
                status = code
                headers = fields
            case .line(let line):
                lines.append(line)
            }
        }
        let body = lines.joined(separator: "\n")
        guard status != 0 else { throw AnthropicError.network("connection closed before a response") }
        guard (200..<300).contains(status) else {
            throw AnthropicError.from(status: status, body: body, headers: headers)
        }
        return body
    }

    /// Feeds transport lines through the SSE parser and event decoder.
    static func pump(
        _ stream: AsyncThrowingStream<TransportEvent, Error>,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var status = 0
        var headers: [String: String] = [:]
        var errorBody: [String] = []
        var parser = SSEParser()
        var sawStop = false
        for try await event in stream {
            switch event {
            case .head(let code, let fields):
                status = code
                headers = fields
            case .line(let line):
                guard (200..<300).contains(status) else {
                    errorBody.append(line)
                    continue
                }
                guard let sse = parser.feed(line) else { continue }
                let decoded = try StreamEventDecoder.decode(sse)
                continuation.yield(decoded)
                if decoded == .messageStop {
                    sawStop = true
                    return
                }
            }
        }
        guard status != 0 else { throw AnthropicError.network("connection closed before a response") }
        guard (200..<300).contains(status) else {
            throw AnthropicError.from(status: status, body: errorBody.joined(separator: "\n"), headers: headers)
        }
        if let sse = parser.finish() {
            let decoded = try StreamEventDecoder.decode(sse)
            continuation.yield(decoded)
            if decoded == .messageStop { sawStop = true }
        }
        if !sawStop {
            throw AnthropicError.network("stream ended before message_stop")
        }
    }

    /// Races `operation` against a deadline.
    static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw AnthropicError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AnthropicError.timedOut }
            return first
        }
    }

    /// URLError and friends → AnthropicError; cancellation passes through.
    static func normalize(_ error: Error) -> Error {
        if error is AnthropicError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return AnthropicError.timedOut
            default: return AnthropicError.network(urlError.localizedDescription)
            }
        }
        return AnthropicError.network(String(describing: error))
    }
}
