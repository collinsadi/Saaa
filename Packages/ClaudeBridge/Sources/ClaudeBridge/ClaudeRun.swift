import Foundation

/// Guardrails for one unattended `claude -p` run. Every run is bounded:
/// explicit tool allowlist, permission mode, turn cap, wall-clock timeout.
public struct ClaudeRunConfiguration: Sendable, Equatable {
    /// The headless prompt.
    public var prompt: String
    /// Working directory — claude loads this directory's CLAUDE.md.
    public var workingDirectory: URL
    /// Tool allowlist (e.g. `["Read", "Glob", "Grep"]`). Empty = no tools.
    public var allowedTools: [String]
    /// `default` denies anything outside the allowlist in headless runs;
    /// `acceptEdits` pre-approves file edits (write-back runs only).
    public var permissionMode: String
    /// Agent-loop turn cap.
    public var maxTurns: Int
    /// JSON Schema the structured result must conform to (`--json-schema`).
    public var jsonSchema: String?
    /// Model name or alias (`--model`); nil = the CLI's configured default.
    public var model: String?
    /// Wall-clock bound; the subprocess is terminated when exceeded.
    public var timeout: Duration

    public init(
        prompt: String,
        workingDirectory: URL,
        allowedTools: [String],
        permissionMode: String = "default",
        maxTurns: Int = 12,
        jsonSchema: String? = nil,
        model: String? = nil,
        timeout: Duration = .seconds(180)
    ) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.allowedTools = allowedTools
        self.permissionMode = permissionMode
        self.maxTurns = maxTurns
        self.jsonSchema = jsonSchema
        self.model = model
        self.timeout = timeout
    }

    /// The argv tail after the binary path. Prompt travels via stdin-less
    /// `-p <prompt>`; output is the JSON result envelope.
    var arguments: [String] {
        var args = ["-p", prompt, "--output-format", "json", "--max-turns", String(maxTurns)]
        if !allowedTools.isEmpty {
            args += ["--allowedTools", allowedTools.joined(separator: ",")]
        }
        args += ["--permission-mode", permissionMode]
        if let jsonSchema {
            args += ["--json-schema", jsonSchema]
        }
        if let model {
            args += ["--model", model]
        }
        return args
    }
}

/// Errors from the bridge, each with a defined fallback upstream.
public enum ClaudeBridgeError: Error, Equatable {
    /// No usable `claude` binary found.
    case claudeNotInstalled
    /// The CLI ran but reported it is not logged in.
    case notAuthenticated
    /// Non-zero exit or is_error result envelope.
    case runFailed(exitCode: Int32, detail: String)
    /// The wall-clock timeout elapsed; the subprocess was terminated.
    case timedOut
    /// The envelope or structured payload could not be decoded.
    case malformedOutput(String)
}

/// The subset of claude's `--output-format json` envelope Saaa consumes.
struct ResultEnvelope: Decodable {
    let type: String
    let subtype: String?
    let isError: Bool?
    let result: String?
    let structuredOutput: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type, subtype, result
        case isError = "is_error"
        case structuredOutput = "structured_output"
    }
}

/// Minimal JSON tree for fields whose shape is schema-driven.
enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if container.decodeNil() { self = .null }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON")
        }
    }
}
