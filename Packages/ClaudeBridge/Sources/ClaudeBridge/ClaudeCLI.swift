import Foundation
import os

/// Locates and runs the user's authenticated `claude` binary as a bounded
/// subprocess. Saaa manages no API keys — everything rides the user's own
/// Claude Code login.
public actor ClaudeCLI {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "ClaudeCLI")

    /// Candidate install locations, checked in order (login-shell PATHs are
    /// not visible to a GUI app, so well-known locations are probed too).
    static let knownLocations = [
        "~/.local/bin/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "~/.claude/local/claude",
    ]

    private var resolvedBinary: URL?

    public init() {}

    /// The `claude` binary, or nil when not installed.
    public func locate() -> URL? {
        if let resolvedBinary { return resolvedBinary }
        for candidate in Self.knownLocations {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                resolvedBinary = URL(filePath: path)
                return resolvedBinary
            }
        }
        // Last resort: PATH lookup via /usr/bin/env (works if the GUI
        // inherited a useful PATH, e.g. launched from a terminal).
        return nil
    }

    /// Runs one configured headless prompt and returns the raw envelope.
    public func run(_ configuration: ClaudeRunConfiguration) async throws -> ClaudeResult {
        guard let binary = locate() else { throw ClaudeBridgeError.claudeNotInstalled }

        let process = Process()
        process.executableURL = binary
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectory
        // Strip variables that would redirect claude to a different config
        // or break auth; keep HOME/PATH so the CLI finds its own state.
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "saaa"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        Self.log.info("claude run: cwd=\(configuration.workingDirectory.path, privacy: .public) turns=\(configuration.maxTurns) tools=\(configuration.allowedTools.joined(separator: ","), privacy: .public)")
        try process.run()

        // Read pipes off-actor so a chatty process can't deadlock the pipe.
        async let outData = Self.readAll(stdout.fileHandleForReading)
        async let errData = Self.readAll(stderr.fileHandleForReading)

        let timedOut = await Self.waitBounded(process, timeout: configuration.timeout)
        let output = await outData
        let errorOutput = await errData

        if timedOut {
            throw ClaudeBridgeError.timedOut
        }
        let exitCode = process.terminationStatus
        let stdoutText = String(decoding: output, as: UTF8.self)
        let stderrText = String(decoding: errorOutput, as: UTF8.self)

        if exitCode != 0 {
            if stdoutText.contains("Invalid API key") || stderrText.contains("Invalid API key")
                || stdoutText.contains("Please run /login") || stderrText.contains("Please run /login") {
                throw ClaudeBridgeError.notAuthenticated
            }
            throw ClaudeBridgeError.runFailed(
                exitCode: exitCode,
                detail: String((stderrText.isEmpty ? stdoutText : stderrText).prefix(500)))
        }
        return try Self.parse(stdoutText)
    }

    // MARK: - Internals

    static func parse(_ stdoutText: String) throws -> ClaudeResult {
        // The envelope is the last JSON object on stdout.
        guard let start = stdoutText.firstIndex(of: "{"),
              let data = String(stdoutText[start...]).data(using: .utf8) else {
            throw ClaudeBridgeError.malformedOutput(String(stdoutText.prefix(300)))
        }
        let envelope: ResultEnvelope
        do {
            envelope = try JSONDecoder().decode(ResultEnvelope.self, from: data)
        } catch {
            throw ClaudeBridgeError.malformedOutput(String(stdoutText.prefix(300)))
        }
        if envelope.isError == true {
            throw ClaudeBridgeError.runFailed(
                exitCode: 0, detail: envelope.result ?? envelope.subtype ?? "unknown")
        }
        return ClaudeResult(
            text: envelope.result ?? "",
            structured: envelope.structuredOutput)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// Waits for exit or timeout; on timeout terminates (then kills).
    private static func waitBounded(_ process: Process, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumeOnce = ResumeOnce(continuation)
            process.terminationHandler = { _ in resumeOnce.resume(false) }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Double(timeout.components.seconds)
            ) {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    resumeOnce.resume(true)
                }
            }
        }
    }
}

/// Resumes a Bool continuation exactly once from competing callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(returning: value)
    }
}

/// One run's outcome: final text plus (when a schema was supplied) the
/// validated structured payload.
public struct ClaudeResult: Sendable {
    public let text: String
    let structured: JSONValue?

    /// Decodes the structured payload (or, failing that, the text as JSON)
    /// into a typed model.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        if let structured {
            let data = try JSONEncoder().encode(CodableJSON(structured))
            return try decoder.decode(T.self, from: data)
        }
        // Fallback: the model sometimes returns the JSON as the text result.
        guard let start = text.firstIndex(of: "{"),
              let data = String(text[start...]).data(using: .utf8) else {
            throw ClaudeBridgeError.malformedOutput(String(text.prefix(300)))
        }
        return try decoder.decode(T.self, from: data)
    }
}

/// Re-encodes the JSONValue tree so `decode` can run any Decodable through it.
private struct CodableJSON: Encodable {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .object(let object):
            try container.encode(object.mapValues(CodableJSON.init))
        case .array(let array):
            try container.encode(array.map(CodableJSON.init))
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .null: try container.encodeNil()
        }
    }
}
