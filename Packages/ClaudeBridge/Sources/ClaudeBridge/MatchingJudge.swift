import Core
import Foundation

/// The typed result of the matching + extraction judgment (the JSON contract
/// from ARCHITECTURE.md §7).
public struct CallJudgment: Sendable, Codable, Equatable {
    public struct Match: Sendable, Codable, Equatable {
        /// Absolute path of the matched project; nil == none / new project.
        public let projectPath: String?
        public let alternates: [String]
        /// 0...1; low confidence surfaces as "unfiled", never a silent write.
        public let confidence: Double
        public let reasoning: String

        enum CodingKeys: String, CodingKey {
            case projectPath = "project_path"
            case alternates, confidence, reasoning
        }

        public init(projectPath: String?, alternates: [String], confidence: Double, reasoning: String) {
            self.projectPath = projectPath
            self.alternates = alternates
            self.confidence = confidence
            self.reasoning = reasoning
        }
    }

    public struct ExtractedItem: Sendable, Codable, Equatable {
        /// decision | data_model | api_shape | preference | requirement |
        /// action_item | risk
        public let kind: String
        public let title: String
        /// Markdown body.
        public let body: String
        public let suggestedFile: String?

        enum CodingKeys: String, CodingKey {
            case kind, title, body
            case suggestedFile = "suggested_file"
        }

        public init(kind: String, title: String, body: String, suggestedFile: String?) {
            self.kind = kind
            self.title = title
            self.body = body
            self.suggestedFile = suggestedFile
        }
    }

    public let match: Match
    /// technical | client_preference | standup | other
    public let callType: String
    public let extracted: [ExtractedItem]

    enum CodingKeys: String, CodingKey {
        case match, extracted
        case callType = "call_type"
    }

    public init(match: Match, callType: String, extracted: [ExtractedItem]) {
        self.match = match
        self.callType = callType
        self.extracted = extracted
    }
}

extension CallJudgment {
    /// Below this confidence a match is PRESENTED AS UNFILED — the suggestion
    /// is shown as an FYI but no write-back is offered (architecture: low
    /// confidence must never lead to a wrong write).
    public static let lowConfidenceThreshold = 0.45

    /// Whether the judgment is confident enough to offer filing + write-back.
    public var isConfident: Bool {
        match.projectPath != nil && match.confidence >= Self.lowConfidenceThreshold
    }
}

/// Builds and runs the READ-ONLY matching judgment over the prefilter
/// shortlist. The write-back run (edit-enabled, Phase 7) is a separate,
/// explicitly confirmed call.
public enum MatchingJudge {

    /// The schema passed via `--json-schema` (ARCHITECTURE.md §7).
    public static let schema = """
    {
      "type": "object",
      "required": ["match", "call_type", "extracted"],
      "properties": {
        "match": {
          "type": "object",
          "required": ["project_path", "alternates", "confidence", "reasoning"],
          "properties": {
            "project_path": { "type": ["string", "null"] },
            "alternates":   { "type": "array", "items": { "type": "string" } },
            "confidence":   { "type": "number", "minimum": 0, "maximum": 1 },
            "reasoning":    { "type": "string" }
          }
        },
        "call_type": { "enum": ["technical", "client_preference", "standup", "other"] },
        "extracted": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["kind", "title", "body"],
            "properties": {
              "kind":  { "enum": ["decision", "data_model", "api_shape",
                                  "preference", "requirement", "action_item", "risk"] },
              "title": { "type": "string" },
              "body":  { "type": "string" },
              "suggested_file": { "type": "string" }
            }
          }
        }
      }
    }
    """

    /// Composes the judgment prompt from the transcript, shortlist, and
    /// calendar context.
    public static func prompt(
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        calendar: CalendarContext?
    ) -> String {
        var sections: [String] = []
        sections.append("""
        You are filing a recorded call into the right local project. Decide which \
        of the candidate projects this conversation belongs to, classify the call, \
        and extract durable context. You may read files inside the candidate \
        directories (CLAUDE.md, README) to inform the decision.

        Rules:
        - If no candidate genuinely fits, set project_path to null — never force a match.
        - confidence is your honest 0..1 estimate; alternates lists other plausible candidates' paths.
        - call_type: technical (architecture/code decisions), client_preference \
        (wishes/constraints from a client), standup (status sync), other.
        - extracted: only durable, project-relevant context worth writing into the \
        repo — decisions with their rationale, new data models or API shapes, client \
        preferences, requirements, action items, risks. Write bodies as tight markdown. \
        No small talk, no transcription artifacts.
        """)
        if let calendar {
            var block = "Calendar event during the call: \"\(calendar.title)\""
            if !calendar.attendees.isEmpty {
                block += "\nAttendees: \(calendar.attendees.joined(separator: ", "))"
            }
            if let notes = calendar.notes, !notes.isEmpty {
                block += "\nNotes: \(notes.prefix(500))"
            }
            sections.append(block)
        }
        let candidates = shortlist
            .map { "- \($0.name) — \($0.path) (prefilter score \(String(format: "%.1f", $0.score)))" }
            .joined(separator: "\n")
        sections.append("Candidate projects (local prefilter, best first):\n\(candidates)")
        sections.append("Transcript (Me = this machine's user, Them = the other side):\n\(transcript.attributedText)")
        return sections.joined(separator: "\n\n")
    }

    /// Runs the read-only judgment. `workingDirectory` should be a neutral
    /// directory; candidates are read via absolute paths with read-only tools.
    public static func judge(
        cli: ClaudeCLI,
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        calendar: CalendarContext?,
        timeout: Duration = .seconds(240)
    ) async throws -> CallJudgment {
        let configuration = ClaudeRunConfiguration(
            prompt: prompt(transcript: transcript, shortlist: shortlist, calendar: calendar),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            allowedTools: ["Read", "Glob", "Grep"],
            permissionMode: "default",
            maxTurns: 16,
            jsonSchema: schema,
            timeout: timeout)
        let result = try await cli.run(configuration)
        return try result.decode(CallJudgment.self)
    }
}
