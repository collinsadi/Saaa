import Foundation

/// What an editor extension reports about the window the user is in: the
/// visible lines, the file's problems, the selection and the last failed
/// terminal command. Exact text, so Look needs no OCR for it. Decoded from
/// the extension's reply on the local editor socket; see
/// `Editors/vscode/PROTOCOL.md`.
public struct EditorContext: Sendable, Equatable, Codable {

    /// A run of consecutive lines, numbered from 1.
    public struct Region: Sendable, Equatable, Codable {
        public var startLine: Int
        public var text: String

        public init(startLine: Int, text: String) {
            self.startLine = startLine
            self.text = text
        }
    }

    /// An error or warning the editor shows for the file.
    public struct Problem: Sendable, Equatable, Codable {
        public var line: Int
        /// "error" or "warning".
        public var severity: String
        public var message: String
        public var source: String?
        public var code: String?

        public init(line: Int, severity: String, message: String, source: String? = nil, code: String? = nil) {
            self.line = line
            self.severity = severity
            self.message = message
            self.source = source
            self.code = code
        }

        public var isError: Bool { severity == "error" }
    }

    /// The most recent terminal command that failed, with the end of its output.
    public struct TerminalRun: Sendable, Equatable, Codable {
        public var command: String
        public var exitCode: Int?
        public var output: String

        public init(command: String, exitCode: Int?, output: String) {
            self.command = command
            self.exitCode = exitCode
            self.output = output
        }
    }

    /// Workspace-relative path, or a file name.
    public var file: String?
    public var language: String?
    public var lineCount: Int?
    public var cursorLine: Int?
    /// What's on screen in the editor; folded code splits it into regions.
    public var visible: [Region]
    /// A few lines around errors that are scrolled out of view.
    public var snippets: [Region]
    public var selection: String?
    public var problems: [Problem]
    public var terminal: TerminalRun?

    public init(
        file: String? = nil, language: String? = nil, lineCount: Int? = nil, cursorLine: Int? = nil,
        visible: [Region] = [], snippets: [Region] = [], selection: String? = nil,
        problems: [Problem] = [], terminal: TerminalRun? = nil
    ) {
        self.file = file
        self.language = language
        self.lineCount = lineCount
        self.cursorLine = cursorLine
        self.visible = visible
        self.snippets = snippets
        self.selection = selection
        self.problems = problems
        self.terminal = terminal
    }

    enum CodingKeys: String, CodingKey {
        case file, language, lineCount, cursorLine, visible, snippets, selection, problems, terminal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount)
        cursorLine = try container.decodeIfPresent(Int.self, forKey: .cursorLine)
        visible = try container.decodeIfPresent([Region].self, forKey: .visible) ?? []
        snippets = try container.decodeIfPresent([Region].self, forKey: .snippets) ?? []
        selection = try container.decodeIfPresent(String.self, forKey: .selection)
        problems = try container.decodeIfPresent([Problem].self, forKey: .problems) ?? []
        terminal = try container.decodeIfPresent(TerminalRun.self, forKey: .terminal)
    }

    /// Nothing worth sending: no visible text, no problems, no failed command.
    public var isEmpty: Bool {
        visible.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && problems.isEmpty && terminal == nil
            && (selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
