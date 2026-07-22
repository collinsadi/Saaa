import ClaudeBridge
import Core
import Foundation
import os

/// How much Code Assist reveals (issue #9): from a Socratic nudge that
/// protects the learning to a full worked approach for real work.
public enum HintLevel: String, CaseIterable, Sendable {
    case nudge
    case approach
    case full

    public var displayName: String {
        switch self {
        case .nudge: "Nudge"
        case .approach: "Approach"
        case .full: "Full"
        }
    }
}

/// Code Assist dispatch (issue #9): one bounded agent run over the OCR
/// text of a user-selected screen region. With a codebase folder the agent
/// runs inside it with read-only tools so help grounds in the user's real
/// code. Never throws — a failed hint is a one-line note, nothing more.
public struct CodeAssistService: Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "CodeAssist")

    private let registry: AgentRegistry

    public init(registry: AgentRegistry = .standard) {
        self.registry = registry
    }

    public func answer(
        screenText: String,
        hintLevel: HintLevel,
        question: String?,
        codebaseFolder: String?,
        timeout: Duration = .seconds(120)
    ) async -> String? {
        let folderURL = codebaseFolder.flatMap { path -> URL? in
            var isDirectory: ObjCBool = false
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(filePath: expanded)
        }
        let prompt = Self.prompt(
            screenText: screenText, hintLevel: hintLevel,
            question: question, hasCodebase: folderURL != nil)

        let installed = registry.installedProviders()
        let preferred = FilingPreferences.fromDefaults().preferredAgent
        let ordered = registry.attemptOrder(
            topCandidateKnownTo: [], preferred: preferred, from: installed)

        for provider in ordered {
            do {
                switch provider.id {
                case .claudeCode:
                    let result = try await ClaudeCLI().run(ClaudeRunConfiguration(
                        prompt: prompt,
                        workingDirectory: folderURL ?? FileManager.default.temporaryDirectory,
                        allowedTools: folderURL == nil ? [] : ["Read", "Glob", "Grep"],
                        maxTurns: folderURL == nil ? 2 : 8,
                        timeout: timeout))
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                case .codex:
                    let text = try await CodexCLI().run(
                        prompt: prompt,
                        model: nil,
                        workingDirectory: folderURL ?? FileManager.default.temporaryDirectory,
                        timeout: timeout)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            } catch {
                Self.log.error("code assist via \(provider.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    static func prompt(
        screenText: String, hintLevel: HintLevel, question: String?, hasCodebase: Bool
    ) -> String {
        let levelInstruction = switch hintLevel {
        case .nudge:
            """
            Give ONE Socratic nudge: a single question or observation that \
            points at the key insight. Never reveal the approach, never write \
            code. Two sentences maximum.
            """
        case .approach:
            """
            Give a concise approach: the key idea and the steps, under 120 \
            words. Name the relevant concepts and pitfalls. No full code — \
            a short fragment to illustrate one step is fine.
            """
        case .full:
            """
            Give a full worked approach: explain the idea first, then show \
            the code, then note edge cases worth testing.
            """
        }
        var sections: [String] = []
        sections.append("""
        You are a pair-programming and learning companion. The user captured \
        a region of their own screen; its recognized text is below. This is \
        for their own development, debugging, and self-directed practice.

        \(levelInstruction)\(hasCodebase
            ? "\n\nYou are running inside the user's project. Read files to ground your help in their real code and cite the paths you used."
            : "")
        """)
        sections.append("Screen region text:\n\(screenText)")
        if let question, !question.isEmpty {
            sections.append("The user's question: \(question)")
        }
        return sections.joined(separator: "\n\n")
    }
}
