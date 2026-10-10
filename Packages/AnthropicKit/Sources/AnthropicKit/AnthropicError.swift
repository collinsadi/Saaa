import Foundation

/// Typed failures from the Claude API bridge. Each maps to a clear upstream
/// fallback: live answers degrade quietly, onboarding shows a specific fix,
/// summaries retry when ``isRetryable``.
public enum AnthropicError: Error, Equatable, Sendable {
    /// No API key in the Keychain yet (onboarding not finished).
    case missingAPIKey
    /// 401: the key was rejected.
    case unauthorized(String)
    /// 403: the key is valid but not allowed to do this.
    case permissionDenied(String)
    /// 400/404/413: the request itself is wrong (bad model id, too large...).
    case invalidRequest(String)
    /// 429: rate limited. `retryAfter` seconds when the header was present.
    case rateLimited(retryAfter: Int?)
    /// 529 or a mid-stream `overloaded_error`.
    case overloaded
    /// 5xx other than 529.
    case server(status: Int, message: String)
    /// Any other non-2xx or error event, with the API's type and message.
    case api(status: Int, type: String?, message: String)
    /// Transport failure (offline, TLS, dropped connection).
    case network(String)
    /// The stream or an error body could not be decoded.
    case malformed(String)
    /// The wall-clock deadline elapsed.
    case timedOut

    /// Worth trying again after a pause.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .network, .timedOut: true
        default: false
        }
    }

    /// Short, calm copy for inline UI. Never contains request content.
    public var userMessage: String {
        switch self {
        case .missingAPIKey: "Add your Claude API key in Settings."
        case .unauthorized: "Claude rejected the API key. Check it in Settings."
        case .permissionDenied: "This API key can't use that model."
        case .invalidRequest(let message): "Claude couldn't take that request (\(message.prefix(80)))."
        case .rateLimited(let after):
            after.map { "Rate limited. Ready again in \($0)s." } ?? "Rate limited. Try again shortly."
        case .overloaded: "Claude is busy right now. Try again in a moment."
        case .server: "Claude had a server error. Try again."
        case .api(_, _, let message): "Claude error: \(message.prefix(80))"
        case .network: "You're offline or the connection dropped."
        case .malformed: "Got an unreadable reply from Claude."
        case .timedOut: "Claude took too long to answer."
        }
    }

    /// Maps an HTTP error response (status + body + headers) to a typed error.
    static func from(status: Int, body: String, headers: [String: String]) -> AnthropicError {
        let parsed = ErrorEnvelope.parse(body)
        let message = parsed?.message ?? (body.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : String(body.prefix(300)))
        switch status {
        case 401: return .unauthorized(message)
        case 403: return .permissionDenied(message)
        case 400, 404, 413: return .invalidRequest(message)
        case 429:
            let header = headers.first { $0.key.lowercased() == "retry-after" }?.value
            return .rateLimited(retryAfter: header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        case 529: return .overloaded
        case 500...599: return .server(status: status, message: message)
        default: return .api(status: status, type: parsed?.type, message: message)
        }
    }

    /// Maps a mid-stream `event: error` payload.
    static func fromStreamError(type: String?, message: String) -> AnthropicError {
        switch type {
        case "overloaded_error": .overloaded
        case "rate_limit_error": .rateLimited(retryAfter: nil)
        case "authentication_error": .unauthorized(message)
        case "permission_error": .permissionDenied(message)
        case "invalid_request_error", "not_found_error", "request_too_large": .invalidRequest(message)
        case "api_error": .server(status: 500, message: message)
        default: .api(status: 200, type: type, message: message)
        }
    }
}

/// `{"type":"error","error":{"type":"...","message":"..."}}`
struct ErrorEnvelope: Decodable {
    struct Inner: Decodable {
        let type: String?
        let message: String?
    }
    let error: Inner?

    var type: String? { error?.type }
    var message: String? { error?.message }

    static func parse(_ text: String) -> ErrorEnvelope? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
    }
}
