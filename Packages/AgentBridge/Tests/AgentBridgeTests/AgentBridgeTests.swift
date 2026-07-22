import ClaudeBridge
import Core
import Foundation
import Matching
import Testing
@testable import AgentBridge

// MARK: - Fakes

private struct FakeProvider: AgentProvider {
    let id: AgentID
    var displayName: String { id.displayName }
    var installed = true

    func isInstalled() -> Bool { installed }
    func verifyAuthenticated() async -> Bool { installed }
    func knownProjects() -> [ProjectCandidate] { [] }
    func judge(
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        provenance: [String: [String]],
        calendar: CalendarContext?,
        pinnedProject: String?,
        instructions: String?,
        model: ModelIntent,
        timeout: Duration
    ) async throws -> CallJudgment {
        throw AgentError.runFailed(detail: "fake")
    }
}

private let claude = FakeProvider(id: .claudeCode)
private let codex = FakeProvider(id: .codex)

// MARK: - Routing

@Suite struct RoutingTests {

    @Test func soleKnowerLeadsRegardlessOfPreference() {
        let registry = AgentRegistry(providers: [claude, codex])
        let order = registry.attemptOrder(
            topCandidateKnownTo: ["codex"], preferred: .claudeCode,
            from: [claude, codex])
        #expect(order.map(\.id) == [.codex, .claudeCode])
    }

    @Test func tieBreaksToPreferredAgent() {
        let registry = AgentRegistry(providers: [claude, codex])
        let order = registry.attemptOrder(
            topCandidateKnownTo: ["claude", "codex"], preferred: .codex,
            from: [claude, codex])
        #expect(order.map(\.id) == [.codex, .claudeCode])
    }

    @Test func tieWithoutPreferenceFollowsRegistryOrder() {
        let registry = AgentRegistry(providers: [claude, codex])
        let order = registry.attemptOrder(
            topCandidateKnownTo: ["claude", "codex"], preferred: nil,
            from: [claude, codex])
        #expect(order.map(\.id) == [.claudeCode, .codex])
    }

    @Test func unknownProjectFallsBackToPreferredTheneRegistryOrder() {
        let registry = AgentRegistry(providers: [claude, codex])
        let order = registry.attemptOrder(
            topCandidateKnownTo: [], preferred: .codex,
            from: [claude, codex])
        #expect(order.map(\.id) == [.codex, .claudeCode])
    }

    @Test func knowerNotInstalledIsNeverAttempted() {
        let registry = AgentRegistry(providers: [claude, codex])
        let order = registry.attemptOrder(
            topCandidateKnownTo: ["codex"], preferred: nil,
            from: [claude]) // codex knows it but is not installed
        #expect(order.map(\.id) == [.claudeCode])
    }

    @Test func nothingInstalledMeansNoAttempts() {
        let registry = AgentRegistry(providers: [claude, codex])
        #expect(registry.attemptOrder(
            topCandidateKnownTo: ["claude"], preferred: nil, from: []).isEmpty)
    }
}

// MARK: - Candidate merging

@Suite struct MergeTests {

    private func candidate(_ path: String, knownTo: Set<String>, claudeMD: Bool = false, agentsMD: Bool = false) -> ProjectCandidate {
        ProjectCandidate(
            path: URL(filePath: path), name: URL(filePath: path).lastPathComponent,
            hasClaudeMD: claudeMD, hasAgentsMD: agentsMD,
            profileTerms: ["term"], knownTo: knownTo)
    }

    @Test func sameProjectFromTwoAgentsUnionsProvenanceAndFlags() {
        let merged = AgentRegistry.mergedCandidates(from: [
            [candidate("/p/acme", knownTo: ["claude"], claudeMD: true)],
            [candidate("/p/acme", knownTo: ["codex"], agentsMD: true),
             candidate("/p/beta", knownTo: ["codex"])],
        ])
        #expect(merged.count == 2)
        let acme = merged.first { $0.path.path == "/p/acme" }
        #expect(acme?.knownTo == ["claude", "codex"])
        #expect(acme?.hasClaudeMD == true)
        #expect(acme?.hasAgentsMD == true)
        #expect(merged.first { $0.path.path == "/p/beta" }?.knownTo == ["codex"])
    }
}

// MARK: - Model mapping and preferences

@Suite struct ModelMapTests {

    @Test func intentsMapPerProvider() {
        #expect(ModelMap.modelName(for: .providerDefault, provider: .claudeCode) == nil)
        #expect(ModelMap.modelName(for: .fast, provider: .claudeCode) == "haiku")
        #expect(ModelMap.modelName(for: .best, provider: .claudeCode) == "opus")
        #expect(ModelMap.modelName(for: .fast, provider: .codex) == "gpt-5.1-codex-mini")
        #expect(ModelMap.modelName(for: .best, provider: .codex) == "gpt-5.1-codex")
    }

    @Test func exactOverrideWinsForEveryProvider() {
        for provider in AgentID.allCases {
            #expect(ModelMap.modelName(for: .exact("my-model"), provider: provider) == "my-model")
        }
    }

    @Test func preferencesReadFromDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "agent-bridge-tests"))
        defer { defaults.removePersistentDomain(forName: "agent-bridge-tests") }

        #expect(FilingPreferences.fromDefaults(defaults)
            == FilingPreferences(preferredAgent: nil, modelIntent: .providerDefault))

        defaults.set("codex", forKey: FilingPreferences.agentKey)
        defaults.set("fast", forKey: FilingPreferences.intentKey)
        #expect(FilingPreferences.fromDefaults(defaults)
            == FilingPreferences(preferredAgent: .codex, modelIntent: .fast))

        // The exact override beats the intent picker.
        defaults.set("  custom-model ", forKey: FilingPreferences.exactModelKey)
        #expect(FilingPreferences.fromDefaults(defaults).modelIntent == .exact("custom-model"))
    }
}

// MARK: - Codex plumbing

@Suite struct CodexCLITests {

    @Test func execArgumentsAreReadOnlyAndBounded() {
        let args = CodexCLI.execArguments(
            prompt: "hello", model: "gpt-5.1-codex", lastMessagePath: "/tmp/x.txt")
        #expect(args.first == "exec")
        if let sandboxIndex = args.firstIndex(of: "--sandbox") {
            #expect(args[sandboxIndex + 1] == "read-only")
        } else {
            Issue.record("--sandbox flag missing")
        }
        #expect(args.contains("--output-last-message") && args.contains("/tmp/x.txt"))
        #expect(args.contains("--model") && args.contains("gpt-5.1-codex"))
        #expect(args.last == "hello")
    }

    @Test func noModelMeansNoModelFlag() {
        let args = CodexCLI.execArguments(prompt: "x", model: nil, lastMessagePath: "/tmp/x")
        #expect(!args.contains("--model"))
    }

    @Test func extractsJSONFromFencedProse() throws {
        let text = """
        Here is the result:
        ```json
        {"match":{"project_path":"/x","alternates":[],"confidence":0.8,"reasoning":"r"},
         "call_type":"technical","extracted":[]}
        ```
        """
        let data = try CodexCLI.extractJSONObject(from: text)
        let judgment = try JSONDecoder().decode(CallJudgment.self, from: data)
        #expect(judgment.match.projectPath == "/x")
        #expect(judgment.filedBy == nil)
    }

    @Test func garbageThrowsMalformed() {
        #expect(throws: AgentError.self) {
            _ = try CodexCLI.extractJSONObject(from: "no json here")
        }
    }
}

// MARK: - Provider wiring

@Suite struct ProviderTests {

    @Test func bridgeErrorsMapToAgentErrors() {
        #expect(ClaudeCodeProvider.mapped(.claudeNotInstalled) == .notInstalled)
        #expect(ClaudeCodeProvider.mapped(.notAuthenticated) == .notAuthenticated)
        #expect(ClaudeCodeProvider.mapped(.timedOut) == .timedOut)
        #expect(ClaudeCodeProvider.mapped(.runFailed(exitCode: 2, detail: "d"))
            == .runFailed(detail: "d"))
        #expect(ClaudeCodeProvider.mapped(.malformedOutput("m")) == .malformedOutput("m"))
    }

    @Test func codexKnownProjectsScansSessionRollouts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-bridge-codex-\(UUID().uuidString)")
        let project = root.appendingPathComponent("real-project")
        let sessions = root.appendingPathComponent(".codex/sessions/2026/07/22")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "# real-project docs".write(
            to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        // Codex nests cwd inside the meta payload.
        let meta = #"{"type":"session_meta","payload":{"id":"s1","cwd":"\#(project.path)"}}"#
        try meta.write(
            to: sessions.appendingPathComponent("rollout-1.jsonl"),
            atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CodexProvider(codexRoot: root.appendingPathComponent(".codex"))
        let projects = provider.knownProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.knownTo == ["codex"])
        #expect(projects.first?.hasAgentsMD == true)
        #expect(projects.first?.name == "real-project")
    }

    @Test func schemaInstructionEmbedsTheJudgmentSchema() {
        #expect(CodexProvider.schemaInstruction.contains("ONLY a JSON object"))
        #expect(CodexProvider.schemaInstruction.contains("project_path"))
    }
}

// MARK: - Diarization

@Suite struct DiarizationTests {

    private var transcript: Transcript {
        Transcript(
            segments: [
                TranscriptSegment(speaker: .me, start: 0, end: 1, text: "Hi all", confidence: 0.9),
                TranscriptSegment(speaker: .them(label: nil), start: 1, end: 2, text: "Hello", confidence: 0.9),
                TranscriptSegment(speaker: .them(label: nil), start: 2, end: 3, text: "Hey", confidence: 0.9),
            ],
            language: "en")
    }

    @Test func applyRelabelsOnlyOpenSegments() {
        let relabeled = DiarizationService.apply(
            [
                .init(index: 0, speaker: "Impostor"),  // Me is locked
                .init(index: 1, speaker: "Jane"),
                .init(index: 2, speaker: "  "),        // blank ignored
                .init(index: 9, speaker: "Ghost"),     // out of range ignored
            ],
            to: transcript)
        #expect(relabeled.segments[0].speaker == .me)
        #expect(relabeled.segments[1].speaker == .them(label: "Jane"))
        #expect(relabeled.segments[2].speaker == .them(label: nil))
    }

    @Test func promptLocksMeAndListsAttendees() {
        let prompt = DiarizationService.prompt(
            transcript: transcript, attendees: ["Jane", "Bola"])
        #expect(prompt.contains("0 [ME]: Hi all"))
        #expect(prompt.contains("1 [open]: Hello"))
        #expect(prompt.contains("Jane, Bola"))
        #expect(prompt.contains("NEVER"))
    }

    @Test func schemaIsValidJSON() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(DiarizationService.schema.utf8)) as? [String: Any]
        #expect(object?["required"] as? [String] == ["assignments", "confidence"])
    }
}

// MARK: - Live answers

@Suite struct LiveAnswerTests {

    @Test func promptIsSuggestionFramedAndCarriesTheWindow() {
        let prompt = LiveAnswerService.prompt(
            window: "Them: Does it work offline?",
            question: "Does it work offline?",
            instructions: "We sell Saaa. Everything is on-device.",
            hasKnowledge: false)
        #expect(prompt.contains("SUGGESTION"))
        #expect(prompt.contains("Does it work offline?"))
        #expect(prompt.contains("We sell Saaa"))
        #expect(prompt.contains("Answer this:"))
        #expect(prompt.contains("unsure"))
    }

    @Test func hotkeyModeAnswersTheLastThing() {
        let prompt = LiveAnswerService.prompt(
            window: "Them: and the pricing?", question: nil,
            instructions: nil, hasKnowledge: true)
        #expect(prompt.contains("Answer the last thing"))
        #expect(prompt.contains("knowledge folder"))
        #expect(!prompt.contains("User context"))
    }
}

// MARK: - Code assist

@Suite struct CodeAssistTests {

    @Test func hintLevelsShapeThePromptDistinctly() {
        let nudge = CodeAssistService.prompt(
            screenText: "for i in range(n): total += i", hintLevel: .nudge,
            question: nil, hasCodebase: false)
        #expect(nudge.contains("Socratic"))
        #expect(nudge.contains("never write \\\ncode") || nudge.contains("never write code")
            || nudge.contains("never write"))
        let approach = CodeAssistService.prompt(
            screenText: "x", hintLevel: .approach, question: nil, hasCodebase: false)
        #expect(approach.contains("No full code"))
        let full = CodeAssistService.prompt(
            screenText: "x", hintLevel: .full, question: nil, hasCodebase: false)
        #expect(full.contains("full worked approach"))
    }

    @Test func promptCarriesScreenTextQuestionAndCodebaseFraming() {
        let prompt = CodeAssistService.prompt(
            screenText: "def solve(nums):", hintLevel: .approach,
            question: "why does this time out", hasCodebase: true)
        #expect(prompt.contains("def solve(nums):"))
        #expect(prompt.contains("why does this time out"))
        #expect(prompt.contains("inside the user's project"))
        #expect(prompt.contains("own development"))
        let bare = CodeAssistService.prompt(
            screenText: "x", hintLevel: .approach, question: nil, hasCodebase: false)
        #expect(!bare.contains("The user's question"))
        #expect(!bare.contains("inside the user's project"))
    }

    @Test func hintLevelStorageKeysAreStable() {
        #expect(HintLevel(rawValue: "nudge") == .nudge)
        #expect(HintLevel(rawValue: "approach") == .approach)
        #expect(HintLevel(rawValue: "full") == .full)
    }
}
