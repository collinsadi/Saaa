import ClaudeBridge
import Core
import Foundation
import Matching

/// Claude Code behind the provider interface: wraps the existing ClaudeCLI
/// and MatchingJudge, mapping bridge errors to provider-neutral ones.
public struct ClaudeCodeProvider: AgentProvider {
    public let id: AgentID = .claudeCode
    public var displayName: String { id.displayName }

    private let cli = ClaudeCLI()

    public init() {}

    public func isInstalled() -> Bool {
        ClaudeCLI.knownLocations.contains {
            FileManager.default.isExecutableFile(
                atPath: ($0 as NSString).expandingTildeInPath)
        }
    }

    public func verifyAuthenticated() async -> Bool {
        do {
            _ = try await cli.run(ClaudeRunConfiguration(
                prompt: "Reply with exactly: OK",
                workingDirectory: FileManager.default.temporaryDirectory,
                allowedTools: [], maxTurns: 1, timeout: .seconds(60)))
            return true
        } catch {
            return false
        }
    }

    public func knownProjects() -> [ProjectCandidate] {
        CandidateEnumerator().enumerate()
    }

    public func judge(
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        provenance: [String: [String]],
        calendar: CalendarContext?,
        pinnedProject: String?,
        model: ModelIntent,
        timeout: Duration
    ) async throws -> CallJudgment {
        do {
            return try await MatchingJudge.judge(
                cli: cli,
                transcript: transcript,
                shortlist: shortlist,
                provenance: provenance,
                calendar: calendar,
                pinnedProject: pinnedProject,
                model: ModelMap.modelName(for: model, provider: id),
                timeout: timeout)
        } catch let error as ClaudeBridgeError {
            throw Self.mapped(error)
        }
    }

    static func mapped(_ error: ClaudeBridgeError) -> AgentError {
        switch error {
        case .claudeNotInstalled: .notInstalled
        case .notAuthenticated: .notAuthenticated
        case .runFailed(_, let detail): .runFailed(detail: detail)
        case .timedOut: .timedOut
        case .malformedOutput(let text): .malformedOutput(text)
        }
    }
}

/// Codex behind the provider interface. Judgments run headless via
/// `codex exec` in a read-only sandbox; the schema rides in the prompt
/// because codex has no native structured-output flag.
public struct CodexProvider: AgentProvider {
    public let id: AgentID = .codex
    public var displayName: String { id.displayName }

    private let cli = CodexCLI()
    /// Injectable for tests; defaults to `~/.codex`.
    private let codexRoot: URL

    public init(codexRoot: URL? = nil) {
        self.codexRoot = codexRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
    }

    public func isInstalled() -> Bool {
        CodexCLI.isInstalled()
    }

    public func verifyAuthenticated() async -> Bool {
        await cli.isAuthenticated()
    }

    /// Codex session rollouts live under `~/.codex/sessions/YYYY/MM/DD/` as
    /// JSONL whose meta line carries the session `cwd`; AGENTS.md is its
    /// project memory file.
    public func knownProjects() -> [ProjectCandidate] {
        let enumerator = CandidateEnumerator()
        let paths = CandidateEnumerator.projectPaths(
            underSessionRoot: codexRoot.appendingPathComponent("sessions"))
        return paths.map { enumerator.profile($0, knownTo: [id.rawValue]) }
    }

    public func judge(
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        provenance: [String: [String]],
        calendar: CalendarContext?,
        pinnedProject: String?,
        model: ModelIntent,
        timeout: Duration
    ) async throws -> CallJudgment {
        let prompt = MatchingJudge.prompt(
            transcript: transcript, shortlist: shortlist,
            provenance: provenance, calendar: calendar,
            pinnedProject: pinnedProject)
            + Self.schemaInstruction
        let text = try await cli.run(
            prompt: prompt,
            model: ModelMap.modelName(for: model, provider: id),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: timeout)
        let data = try CodexCLI.extractJSONObject(from: text)
        do {
            return try JSONDecoder().decode(CallJudgment.self, from: data)
        } catch {
            throw AgentError.malformedOutput(String(text.prefix(300)))
        }
    }

    static let schemaInstruction = """


    Respond with ONLY a JSON object (no markdown fences, no prose) that \
    validates against this JSON Schema:
    \(MatchingJudge.schema)
    """
}
