import ClaudeBridge
import Core
import Foundation
import os

/// Live Assist dispatch (issue #8): one bounded, fast agent run over the
/// rolling conversation window. Answers are SUGGESTIONS the user adapts in
/// their own words, never autopilot, and the prompt says so. When a
/// knowledge folder is configured the agent grounds claims by reading it
/// with read-only tools; without one it answers from the user's Live
/// Assist prompt alone and is told to flag uncertainty.
public struct LiveAnswerService: Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "LiveAnswer")

    private let registry: AgentRegistry

    public init(registry: AgentRegistry = .standard) {
        self.registry = registry
    }

    /// Returns a suggested answer, or nil when no agent is available or
    /// the run fails. Never throws — Live Assist must degrade quietly
    /// mid-call.
    public func answer(
        window: String,
        question: String?,
        instructions: String?,
        knowledgeFolder: String?,
        timeout: Duration = .seconds(75)
    ) async -> String? {
        let kbURL = knowledgeFolder
            .flatMap { path -> URL? in
                var isDirectory: ObjCBool = false
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return nil }
                return URL(filePath: expanded)
            }
        let prompt = Self.prompt(
            window: window, question: question,
            instructions: instructions, hasKnowledge: kbURL != nil)

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
                        workingDirectory: kbURL ?? FileManager.default.temporaryDirectory,
                        allowedTools: kbURL == nil ? [] : ["Read", "Glob", "Grep"],
                        maxTurns: kbURL == nil ? 2 : 6,
                        model: ModelMap.modelName(for: .fast, provider: .claudeCode),
                        timeout: timeout))
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                case .codex:
                    let text = try await CodexCLI().run(
                        prompt: prompt,
                        model: ModelMap.modelName(for: .fast, provider: .codex),
                        workingDirectory: kbURL ?? FileManager.default.temporaryDirectory,
                        timeout: timeout)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            } catch {
                Self.log.error("live answer via \(provider.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    static func prompt(
        window: String, question: String?, instructions: String?, hasKnowledge: Bool
    ) -> String {
        var sections: [String] = []
        sections.append("""
        You are a live call copilot for the user (the ME side of this \
        conversation). Suggest what they could say next, in under 120 words, \
        as plain text with no markdown. This is a SUGGESTION the user adapts \
        in their own words, not something read verbatim. Be concrete and \
        factual.\(hasKnowledge
            ? " Ground every claim in the knowledge folder you are running in; read files as needed. If the folder does not support a claim, say so briefly."
            : " If you cannot verify a claim, say what you are unsure of in one short clause.")
        """)
        if let instructions, !instructions.isEmpty {
            sections.append("User context and instructions:\n\(instructions)")
        }
        sections.append("Recent conversation (Me = the user, Them = the other side):\n\(window)")
        sections.append(
            question.map { "Answer this: \($0)" }
                ?? "Answer the last thing the other side said.")
        return sections.joined(separator: "\n\n")
    }
}
