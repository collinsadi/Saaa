import Foundation

/// What a transport reports: the response head once, then body lines.
public enum TransportEvent: Sendable, Equatable {
    case head(status: Int, headers: [String: String])
    /// One body line, terminator stripped. Empty lines are preserved.
    case line(String)
}

/// The network seam. Production uses ``URLSessionTransport``; tests feed
/// scripted lines.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) -> AsyncThrowingStream<TransportEvent, Error>
}

/// `URLSession.bytes(for:)` behind the transport seam. One shared session so
/// TLS + HTTP/2 connections are reused across requests (first-token latency).
public struct URLSessionTransport: HTTPTransport {

    public static let shared = URLSessionTransport()

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 600
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) -> AsyncThrowingStream<TransportEvent, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AnthropicError.network("No HTTP response")
                    }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        if let key = key as? String { headers[key.lowercased()] = "\(value)" }
                    }
                    continuation.yield(.head(status: http.statusCode, headers: headers))
                    var splitter = LineSplitter()
                    for try await byte in bytes {
                        if let line = splitter.push(byte) {
                            continuation.yield(.line(line))
                        }
                    }
                    if let rest = splitter.finish() {
                        continuation.yield(.line(rest))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
