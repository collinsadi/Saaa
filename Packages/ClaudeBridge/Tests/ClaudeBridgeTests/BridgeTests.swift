import Core
import Foundation
import Testing
@testable import ClaudeBridge

@Test func moduleLinksAndReportsIdentity() {
    #expect(ClaudeBridgeModule.name == "ClaudeBridge")
}

@Suite struct RunConfigurationTests {

    @Test func argumentsCarryEveryGuardrail() {
        let config = ClaudeRunConfiguration(
            prompt: "hello",
            workingDirectory: URL(filePath: "/tmp"),
            allowedTools: ["Read", "Grep"],
            permissionMode: "default",
            maxTurns: 7,
            jsonSchema: "{}")
        let args = config.arguments
        #expect(args.contains("--output-format"))
        #expect(args.contains("json"))
        #expect(args.contains("--max-turns") && args.contains("7"))
        #expect(args.contains("--allowedTools") && args.contains("Read,Grep"))
        #expect(args.contains("--permission-mode") && args.contains("default"))
        #expect(args.contains("--json-schema") && args.contains("{}"))
        #expect(args.first == "-p" && args[1] == "hello")
    }

    @Test func noToolsMeansNoAllowlistFlag() {
        let config = ClaudeRunConfiguration(
            prompt: "x", workingDirectory: URL(filePath: "/tmp"), allowedTools: [])
        #expect(!config.arguments.contains("--allowedTools"))
    }
}

@Suite struct EnvelopeParsingTests {

    @Test func parsesSuccessEnvelopeWithStructuredOutput() throws {
        let stdout = """
        {"type":"result","subtype":"success","is_error":false,"result":"done",
         "structured_output":{"match":{"project_path":"/x","alternates":[],
         "confidence":0.9,"reasoning":"clear"},"call_type":"technical","extracted":[]}}
        """
        let result = try ClaudeCLI.parse(stdout)
        let judgment = try result.decode(CallJudgment.self)
        #expect(judgment.match.projectPath == "/x")
        #expect(judgment.match.confidence == 0.9)
        #expect(judgment.callType == "technical")
    }

    @Test func decodeFallsBackToTextJSON() throws {
        let stdout = """
        {"type":"result","subtype":"success","is_error":false,
         "result":"{\\"match\\":{\\"project_path\\":null,\\"alternates\\":[],\\"confidence\\":0.2,\\"reasoning\\":\\"unclear\\"},\\"call_type\\":\\"other\\",\\"extracted\\":[]}"}
        """
        let judgment = try ClaudeCLI.parse(stdout).decode(CallJudgment.self)
        #expect(judgment.match.projectPath == nil)
        #expect(judgment.callType == "other")
    }

    @Test func errorEnvelopeThrows() {
        let stdout = #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"ran out"}"#
        #expect(throws: ClaudeBridgeError.self) {
            _ = try ClaudeCLI.parse(stdout)
        }
    }

    @Test func garbageThrowsMalformed() {
        #expect(throws: ClaudeBridgeError.self) {
            _ = try ClaudeCLI.parse("not json at all")
        }
    }

    @Test func leadingNoiseBeforeEnvelopeIsTolerated() throws {
        let stdout = """
        some banner noise
        {"type":"result","subtype":"success","is_error":false,"result":"ok"}
        """
        let result = try ClaudeCLI.parse(stdout)
        #expect(result.text == "ok")
    }
}

@Suite struct PromptBuilderTests {

    @Test func promptCarriesAllSections() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(speaker: .me, start: 0, end: 1, text: "We ship the API Friday", confidence: 0.9),
                TranscriptSegment(speaker: .them(label: nil), start: 1, end: 2, text: "Great", confidence: 0.9),
            ],
            language: "en")
        let prompt = MatchingJudge.prompt(
            transcript: transcript,
            shortlist: [(path: "/p/acme", name: "acme", score: 8.5)],
            calendar: CalendarContext(title: "Acme sync", attendees: ["jane@acme.com"]))
        #expect(prompt.contains("Me: We ship the API Friday"))
        #expect(prompt.contains("Them: Great"))
        #expect(prompt.contains("/p/acme"))
        #expect(prompt.contains("Acme sync"))
        #expect(prompt.contains("project_path to null"))
    }

    @Test func customInstructionsLandBetweenRulesAndTranscript() {
        let transcript = Transcript(
            segments: [TranscriptSegment(speaker: .me, start: 0, end: 1, text: "Hello", confidence: 0.9)],
            language: "en")
        let prompt = MatchingJudge.prompt(
            transcript: transcript,
            shortlist: [(path: "/p/acme", name: "acme", score: 4)],
            calendar: nil,
            instructions: "Global style.\n\nOnly if you classify this call as standup:\nOne line per item.")
        #expect(prompt.contains("User filing instructions"))
        #expect(prompt.contains("Global style."))
        let instructionsIndex = prompt.range(of: "User filing instructions")!.lowerBound
        let transcriptIndex = prompt.range(of: "Transcript (Me =")!.lowerBound
        #expect(instructionsIndex < transcriptIndex)
        // Absent instructions add no section.
        let bare = MatchingJudge.prompt(
            transcript: transcript,
            shortlist: [(path: "/p/acme", name: "acme", score: 4)],
            calendar: nil)
        #expect(!bare.contains("User filing instructions"))
    }

    @Test func schemaIsValidJSON() throws {
        let data = MatchingJudge.schema.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["required"] as? [String] == ["match", "call_type", "extracted"])
    }
}

/// Live smoke against the user's real authenticated CLI — opt-in.
@Suite struct LiveClaudeTests {
    static let enabled = ProcessInfo.processInfo.environment["SAAA_CLAUDE_SMOKE"] == "1"

    @Test(.enabled(if: enabled)) func structuredOutputRoundTrip() async throws {
        struct Answer: Decodable { let answer: Int }
        let cli = ClaudeCLI()
        let result = try await cli.run(ClaudeRunConfiguration(
            prompt: "What is 20+22? Respond per the schema.",
            workingDirectory: FileManager.default.temporaryDirectory,
            allowedTools: [],
            maxTurns: 2,
            jsonSchema: #"{"type":"object","required":["answer"],"properties":{"answer":{"type":"integer"}}}"#,
            timeout: .seconds(120)))
        let answer = try result.decode(Answer.self)
        #expect(answer.answer == 42)
    }
}
