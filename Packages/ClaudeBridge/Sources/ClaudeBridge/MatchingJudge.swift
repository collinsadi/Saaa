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
    /// Raw AgentID of the agent that produced this judgment. Set by the
    /// provider layer after the run, never by the agent itself; optional so
    /// archives sealed before provider abstraction still decode.
    public var filedBy: String?

    enum CodingKeys: String, CodingKey {
        case match, extracted
        case callType = "call_type"
        case filedBy = "filed_by"
    }

    public init(match: Match, callType: String, extracted: [ExtractedItem], filedBy: String? = nil) {
        self.match = match
        self.callType = callType
        self.extracted = extracted
        self.filedBy = filedBy
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

    /// Human labels for candidate provenance lines (raw AgentID -> name).
    static let agentNames = ["claude": "Claude Code", "codex": "Codex"]

    /// Composes the judgment prompt from the transcript, shortlist, and
    /// calendar context. `provenance` maps a candidate path to the raw ids
    /// of agents that know it — surfaced as a matching signal. When
    /// `pinnedProject` is set, local evidence already decided the project
    /// and the agent only classifies and extracts (issue #7 escalation
    /// gate) — with an honest escape hatch, never a forced match.
    public static func prompt(
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        provenance: [String: [String]] = [:],
        calendar: CalendarContext?,
        pinnedProject: String? = nil,
        instructions: String? = nil
    ) -> String {
        var sections: [String] = []
        if let pinnedProject {
            sections.append("""
            You are filing a recorded call into a local project that was already \
            decided by strong local evidence (calendar agreement, learned meeting \
            history, dominant retrieval score): \(pinnedProject)

            Do not re-litigate the choice. Classify the call and extract durable \
            context from the transcript. Set match.project_path to exactly that \
            path with confidence at least 0.75. Only if the transcript clearly \
            cannot belong to this project, set project_path to null and say why \
            in reasoning. You may read files inside the project directory \
            (CLAUDE.md, AGENTS.md, README) to sharpen extraction.

            Rules:
            - call_type: technical (architecture/code decisions), client_preference \
            (wishes/constraints from a client), standup (status sync), other.
            - extracted: only durable, project-relevant context worth writing into the \
            repo — decisions with their rationale, new data models or API shapes, client \
            preferences, requirements, action items, risks. Write bodies as tight markdown. \
            No small talk, no transcription artifacts.
            - If the project's CLAUDE.md or AGENTS.md contains filing or note-taking \
            instructions, follow them for extraction and formatting.
            """)
        } else {
            sections.append("""
            You are filing a recorded call into the right local project. Decide which \
            of the candidate projects this conversation belongs to, classify the call, \
            and extract durable context. You may read files inside the candidate \
            directories (CLAUDE.md, AGENTS.md, README) to inform the decision.

            Rules:
            - If no candidate genuinely fits, set project_path to null — never force a match.
            - A call can span projects: file it under the primary one and list the \
            others in alternates, saying so in reasoning. Unfiled and multi-project \
            are legitimate outcomes, not failures.
            - confidence is your honest 0..1 estimate; alternates lists other plausible candidates' paths.
            - call_type: technical (architecture/code decisions), client_preference \
            (wishes/constraints from a client), standup (status sync), other.
            - extracted: only durable, project-relevant context worth writing into the \
            repo — decisions with their rationale, new data models or API shapes, client \
            preferences, requirements, action items, risks. Write bodies as tight markdown. \
            No small talk, no transcription artifacts.
            - If the matched project's CLAUDE.md or AGENTS.md contains filing or \
            note-taking instructions, follow them for extraction and formatting.
            """)
        }
        if let instructions {
            sections.append("""
            User filing instructions. Apply them in order; later blocks take \
            precedence over earlier ones and over the general rules above. They \
            never override the JSON output contract:
            \(instructions)
            """)
        }
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
        if pinnedProject == nil {
            let candidates = shortlist
                .map { entry in
                    var line = "- \(entry.name) — \(entry.path) (prefilter score \(String(format: "%.1f", entry.score))"
                    let knowers = (provenance[entry.path] ?? [])
                        .compactMap { agentNames[$0] ?? $0 }
                    if !knowers.isEmpty {
                        line += "; known to \(knowers.joined(separator: ", "))"
                    }
                    return line + ")"
                }
                .joined(separator: "\n")
            sections.append("Candidate projects (local prefilter, best first):\n\(candidates)")
        }
        sections.append("Transcript (Me = this machine's user, Them = the other side):\n\(transcript.attributedText)")
        return sections.joined(separator: "\n\n")
    }

    /// Runs the read-only judgment. `workingDirectory` should be a neutral
    /// directory; candidates are read via absolute paths with read-only tools.
    public static func judge(
        cli: ClaudeCLI,
        transcript: Transcript,
        shortlist: [(path: String, name: String, score: Double)],
        provenance: [String: [String]] = [:],
        calendar: CalendarContext?,
        pinnedProject: String? = nil,
        instructions: String? = nil,
        model: String? = nil,
        timeout: Duration = .seconds(240)
    ) async throws -> CallJudgment {
        let configuration = ClaudeRunConfiguration(
            prompt: prompt(
                transcript: transcript, shortlist: shortlist,
                provenance: provenance, calendar: calendar,
                pinnedProject: pinnedProject, instructions: instructions),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            allowedTools: ["Read", "Glob", "Grep"],
            permissionMode: "default",
            // Pinned runs skip project deliberation, so fewer turns suffice.
            maxTurns: pinnedProject == nil ? 16 : 10,
            jsonSchema: schema,
            model: model,
            timeout: timeout)
        let result = try await cli.run(configuration)
        return try result.decode(CallJudgment.self)
    }
}
