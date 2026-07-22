import Foundation
import os

/// Locates and runs the user's authenticated `codex` binary as a bounded
/// subprocess, mirroring ClaudeCLI's guardrails: read-only sandbox, explicit
/// wall-clock timeout, no API keys managed by Saaa.
public actor CodexCLI {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "CodexCLI")

    /// Candidate install locations, checked in order (GUI apps do not see
    /// login-shell PATHs, so well-known locations are probed).
    static let knownLocations = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.local/bin/codex",
        "~/.npm-global/bin/codex",
        "~/.bun/bin/codex",
    ]

    private var resolvedBinary: URL?

    public init() {}

    /// The `codex` binary, or nil when not installed.
    public func locate() -> URL? {
        if let resolvedBinary { return resolvedBinary }
        for candidate in Self.knownLocations {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                resolvedBinary = URL(filePath: path)
                return resolvedBinary
            }
        }
        return nil
    }

    nonisolated public static func isInstalled() -> Bool {
        knownLocations.contains {
            FileManager.default.isExecutableFile(
                atPath: ($0 as NSString).expandingTildeInPath)
        }
    }

    /// `codex login status` exits 0 only when a usable login exists.
    public func isAuthenticated() async -> Bool {
        guard let binary = locate() else { return false }
        let outcome = try? await Self.runBounded(
            binary: binary, arguments: ["login", "status"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: .seconds(20))
        return outcome?.exitCode == 0
    }

    /// The argv for one read-only headless exec run. `codex exec` cannot
    /// enforce a JSON schema natively, so the schema rides in the prompt and
    /// the final message is parsed from `--output-last-message`.
    nonisolated static func execArguments(
        prompt: String, model: String?, lastMessagePath: String
    ) -> [String] {
        var args = [
            "exec",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--color", "never",
            "--output-last-message", lastMessagePath,
        ]
        if let model {
            args += ["--model", model]
        }
        args.append(prompt)
        return args
    }

    /// Runs one headless prompt; returns the agent's final message text.
    public func run(
        prompt: String, model: String?, workingDirectory: URL, timeout: Duration
    ) async throws -> String {
        guard let binary = locate() else { throw AgentError.notInstalled }
        let lastMessage = FileManager.default.temporaryDirectory
            .appendingPathComponent("saaa-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lastMessage) }

        Self.log.info("codex run: cwd=\(workingDirectory.path, privacy: .public) model=\(model ?? "default", privacy: .public)")
        let outcome = try await Self.runBounded(
            binary: binary,
            arguments: Self.execArguments(
                prompt: prompt, model: model, lastMessagePath: lastMessage.path),
            workingDirectory: workingDirectory,
            timeout: timeout)

        if outcome.timedOut { throw AgentError.timedOut }
        if outcome.exitCode != 0 {
            let combined = outcome.stdout + outcome.stderr
            if combined.localizedCaseInsensitiveContains("not logged in")
                || combined.localizedCaseInsensitiveContains("login") && combined.localizedCaseInsensitiveContains("required") {
                throw AgentError.notAuthenticated
            }
            throw AgentError.runFailed(detail: String(combined.suffix(500)))
        }
        guard let text = try? String(contentsOf: lastMessage, encoding: .utf8),
              !text.isEmpty else {
            throw AgentError.malformedOutput("empty final message")
        }
        return text
    }

    /// Extracts the outermost JSON object from a final message that may be
    /// wrapped in prose or markdown fences.
    nonisolated static func extractJSONObject(from text: String) throws -> Data {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8) else {
            throw AgentError.malformedOutput(String(text.prefix(300)))
        }
        return data
    }

    // MARK: - Bounded subprocess

    struct Outcome {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func runBounded(
        binary: URL, arguments: [String], workingDirectory: URL, timeout: Duration
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        async let outData = readAll(stdout.fileHandleForReading)
        async let errData = readAll(stderr.fileHandleForReading)
        let timedOut = await waitBounded(process, timeout: timeout)
        return Outcome(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: String(decoding: await outData, as: UTF8.self),
            stderr: String(decoding: await errData, as: UTF8.self),
            timedOut: timedOut)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

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
