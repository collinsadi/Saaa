import Foundation

/// What kind of moment a screen shows, decided on the Mac before anything
/// is sent. It picks the task Claude gets for a Look.
public enum ScreenScene: String, Sendable, Codable, Equatable, CaseIterable {
    /// A compiler or runtime error, a stack trace, a failing test.
    case error
    /// A coding problem statement: examples, input and output, constraints.
    case problem
    /// Source code with no visible error.
    case code
    /// A coding question in prose: a ticket, a doc, a chat message.
    case question
    /// Anything else: slides, a document, a dashboard.
    case other

    public var label: String {
        switch self {
        case .error: "Error"
        case .problem: "Problem"
        case .code: "Code"
        case .question: "Question"
        case .other: "Screen"
        }
    }
}

/// Where a snapshot's text came from.
public enum ScreenSource: String, Sendable, Codable, Equatable {
    /// Read from a window's pixels by on-device text recognition.
    case window
    /// Exact text from an editor extension: the visible lines, problems,
    /// the selection and the last failed terminal command.
    case editor
}

/// The text Saaa read from one window, on this Mac, after redaction. It is
/// exactly what a Look sends to Claude: the screenshot itself never leaves
/// the capture call, and this text is kept in memory only, never sealed.
public struct ScreenSnapshot: Sendable, Equatable {
    public var appName: String
    public var windowTitle: String?
    /// Redacted text, rows in reading order, indentation rebuilt for code.
    public var text: String
    public var scene: ScreenScene
    /// Secrets masked before sending.
    public var redactions: Int
    /// The window held more text than one Look sends.
    public var truncated: Bool
    public var capturedAt: Date
    public var source: ScreenSource

    public init(
        appName: String, windowTitle: String? = nil, text: String, scene: ScreenScene,
        redactions: Int = 0, truncated: Bool = false, capturedAt: Date = .now, source: ScreenSource = .window
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.text = text
        self.scene = scene
        self.redactions = redactions
        self.truncated = truncated
        self.capturedAt = capturedAt
        self.source = source
    }

    /// "Xcode · PromptComposer.swift", or just the app.
    public var sourceLabel: String {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title != appName else { return appName }
        return "\(appName) · \(title)"
    }

    public var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// Why a Look didn't produce a snapshot. Messages are calm and say what to do.
public enum ScreenReadError: Error, Sendable, Equatable {
    /// Screen Recording isn't allowed yet; the system prompt was shown.
    case permissionNeeded
    /// Nothing on screen to read besides Saaa.
    case noWindow
    /// The window had no readable text.
    case nothingReadable
    case failed(String)

    public var userMessage: String {
        switch self {
        case .permissionNeeded:
            "Look needs Screen Recording. Allow Saaa in System Settings, then restart Saaa after this call."
        case .noWindow:
            "There's no window to look at. Bring the window you want to the front."
        case .nothingReadable:
            "Saaa couldn't read any text in that window."
        case .failed:
            "Saaa couldn't read the screen. Try again."
        }
    }
}
