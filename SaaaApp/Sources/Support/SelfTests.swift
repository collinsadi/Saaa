import AnthropicKit
import AppKit
import AudioCapture
import CallSession
import Foundation
import Transcription

/// Headless checks for development (`Saaa --selftest-<name> <out-dir>`):
/// run inside the app so they exercise its real permissions, write a report,
/// then quit. Never part of a normal launch.
enum SelfTests {

    static var requested: String? {
        CommandLine.arguments.first { $0.hasPrefix("--selftest-") }.map { String($0.dropFirst("--selftest-".count)) }
    }

    @MainActor
    static func run(_ name: String) {
        let arguments = CommandLine.arguments
        let outputDirectory = arguments.last.flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
            ?? FileManager.default.temporaryDirectory
        Task {
            let report: String
            do {
                switch name {
                case "transcribe":
                    report = try await SpeechSelfTest.run(realtime: true).description
                case "pipeline":
                    report = try await PipelineSelfTest.run()
                case "capture":
                    report = try await captureCheck()
                default:
                    report = "unknown self-test \(name)"
                }
            } catch {
                report = "FAILED: \(error)"
            }
            let url = outputDirectory.appendingPathComponent("selftest-\(name).txt")
            try? report.write(to: url, atomically: true, encoding: .utf8)
            print(report)
            NSApplication.shared.terminate(nil)
        }
    }

    /// Four seconds of all system audio + mic through the live stream.
    static func captureCheck() async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saaa-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = CaptureSession(configuration: CaptureConfiguration(target: .allSystemAudio, outputDirectory: directory))
        let counter = Task { () -> (mic: Int, system: Int, contiguous: Bool) in
            var mic = 0
            var system = 0
            var next: [LiveAudioChunk.Lane: Int64] = [.mic: 0, .system: 0]
            var contiguous = true
            for await chunk in session.liveAudio {
                if chunk.startFrame != next[chunk.lane] { contiguous = false }
                next[chunk.lane] = chunk.startFrame + Int64(chunk.samples.count)
                if chunk.lane == .mic { mic += chunk.samples.count } else { system += chunk.samples.count }
            }
            return (mic, system, contiguous)
        }
        try await session.start()
        try await Task.sleep(for: .seconds(4))
        let result = try await session.stop()
        let counts = await counter.value
        return """
        backend: \(result.backendUsed == .processTap ? "process tap" : "ScreenCaptureKit")
        duration: \(String(format: "%.2f", result.duration)) s
        live mic samples: \(counts.mic) (\(String(format: "%.2f", Double(counts.mic) / 16_000)) s)
        live system samples: \(counts.system) (\(String(format: "%.2f", Double(counts.system) / 16_000)) s)
        contiguous: \(counts.contiguous)
        """
    }
}
