import ClaudeBridge
import Core
import Foundation
import os

/// Shared diarization service (issue #4), agent-from-text implementation.
/// Live dual-stream calls keep their ground truth: Me segments are LOCKED
/// and the agent only splits and names the remote side. Single-track
/// imports get every unattributed segment considered. Speaker names are
/// pre-populated from calendar attendees. Any uncertainty or error returns
/// nil and the caller exports without diarization — it never blocks.
public struct DiarizationService: Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "Diarization")

    /// Below this self-reported confidence the result is discarded.
    public static let confidenceFloor = 0.5

    private let registry: AgentRegistry

    public init(registry: AgentRegistry = .standard) {
        self.registry = registry
    }

    /// Returns a relabeled transcript, or nil when no agent is available,
    /// the run fails, or the agent is not confident.
    public func diarize(
        transcript: Transcript,
        attendees: [String],
        timeout: Duration = .seconds(180)
    ) async -> Transcript? {
        let installed = registry.installedProviders()
        let preferences = FilingPreferences.fromDefaults()
        let ordered = registry.attemptOrder(
            topCandidateKnownTo: [], preferred: preferences.preferredAgent, from: installed)
        let prompt = Self.prompt(transcript: transcript, attendees: attendees)

        for provider in ordered {
            do {
                let verdict: Verdict
                switch provider.id {
                case .claudeCode:
                    let result = try await ClaudeCLI().run(ClaudeRunConfiguration(
                        prompt: prompt,
                        workingDirectory: FileManager.default.temporaryDirectory,
                        allowedTools: [],
                        maxTurns: 4,
                        jsonSchema: Self.schema,
                        model: ModelMap.modelName(for: .fast, provider: .claudeCode),
                        timeout: timeout))
                    verdict = try result.decode(Verdict.self)
                case .codex:
                    let text = try await CodexCLI().run(
                        prompt: prompt + "\n\nRespond with ONLY a JSON object matching this schema:\n" + Self.schema,
                        model: ModelMap.modelName(for: .fast, provider: .codex),
                        workingDirectory: FileManager.default.temporaryDirectory,
                        timeout: timeout)
                    verdict = try JSONDecoder().decode(
                        Verdict.self, from: CodexCLI.extractJSONObject(from: text))
                }
                guard verdict.confidence >= Self.confidenceFloor else {
                    Self.log.info("diarization below confidence floor — falling back plain")
                    return nil
                }
                return Self.apply(verdict.assignments, to: transcript)
            } catch {
                Self.log.error("diarization via \(provider.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Contract

    struct Verdict: Decodable {
        struct Assignment: Decodable {
            let index: Int
            let speaker: String
        }
        let assignments: [Assignment]
        let confidence: Double
    }

    static let schema = """
    {
      "type": "object",
      "required": ["assignments", "confidence"],
      "properties": {
        "assignments": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["index", "speaker"],
            "properties": {
              "index": { "type": "integer" },
              "speaker": { "type": "string" }
            }
          }
        },
        "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
      }
    }
    """

    static func prompt(transcript: Transcript, attendees: [String]) -> String {
        var sections: [String] = []
        sections.append("""
        Split and name the speakers in this call transcript. Segments marked \
        [ME] are ground truth from a separate microphone channel: NEVER \
        reassign them, and never use their speaker for any other segment. \
        Only assign speakers to the numbered segments listed as open. Use \
        short human names. If several remote people speak, tell them apart \
        by turn-taking, self-references, and how they address each other. \
        Report confidence honestly: use a value below 0.5 if you are \
        guessing, and only include assignments you actually believe.
        """)
        if !attendees.isEmpty {
            sections.append("Likely participants (from the calendar): \(attendees.joined(separator: ", "))")
        }
        let lines = transcript.segments.enumerated().map { index, segment in
            switch segment.speaker {
            case .me:
                "\(index) [ME]: \(segment.text)"
            case .them(let label):
                "\(index) [open\(label.map { ", currently \($0)" } ?? "")]: \(segment.text)"
            }
        }
        sections.append("Transcript:\n\(lines.joined(separator: "\n"))")
        return sections.joined(separator: "\n\n")
    }

    /// Applies assignments to the transcript. Me segments and out-of-range
    /// or blank assignments are ignored — ground truth is never overwritten.
    static func apply(_ assignments: [Verdict.Assignment], to transcript: Transcript) -> Transcript {
        var segments = transcript.segments
        for assignment in assignments {
            guard segments.indices.contains(assignment.index) else { continue }
            let name = assignment.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let segment = segments[assignment.index]
            guard case .them = segment.speaker else { continue }
            segments[assignment.index] = TranscriptSegment(
                speaker: .them(label: name),
                start: segment.start, end: segment.end,
                text: segment.text, confidence: segment.confidence)
        }
        return Transcript(segments: segments, language: transcript.language)
    }
}
