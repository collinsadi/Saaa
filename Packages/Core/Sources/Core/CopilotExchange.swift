import Foundation

/// One entry in a call's copilot thread: a quick action, a typed question,
/// or an automatic answer to something the other side asked.
public struct CopilotExchange: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case action
        case ask
        case suggestion
    }

    public var id: UUID
    public var kind: Kind
    /// Quick action id, when `kind == .action` or `.suggestion`.
    public var actionID: String?
    /// "Answer", "What to say", or the user's own question.
    public var title: String
    /// The detected question (suggestions) or the typed ask.
    public var prompt: String?
    public var response: String
    /// Call time in seconds when it was asked.
    public var callTime: TimeInterval
    public var createdAt: Date
    public var isPinned: Bool
    public var failure: String?
    public var model: String?
    /// First-token latency in seconds, when measured.
    public var firstTokenSeconds: Double?

    public init(
        id: UUID = UUID(), kind: Kind, actionID: String? = nil, title: String, prompt: String? = nil,
        response: String = "", callTime: TimeInterval, createdAt: Date = .now, isPinned: Bool = false,
        failure: String? = nil, model: String? = nil, firstTokenSeconds: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.actionID = actionID
        self.title = title
        self.prompt = prompt
        self.response = response
        self.callTime = callTime
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.failure = failure
        self.model = model
        self.firstTokenSeconds = firstTokenSeconds
    }
}

/// One turn of "Ask this call" after the meeting.
public struct ChatTurn: Sendable, Codable, Equatable, Identifiable {
    public enum Role: String, Sendable, Codable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}
