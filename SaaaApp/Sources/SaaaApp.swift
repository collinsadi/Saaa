import AppKit
import SwiftUI
import AudioCapture
import CalendarContext
import CallSession
import ClaudeBridge
import Core
import DesignSystem
import Extraction
import Matching
import Persistence
import Transcription

/// Saaa — every call, in context.
///
/// Phase-2 state: the menu-bar placeholder now hosts the internal audio
/// capture harness used to validate the process-tap engine on real calls.
/// The notch island and real windows arrive in Phase 9.
@main
struct SaaaApp: App {
    @State private var harness = CaptureHarness()

    var body: some Scene {
        MenuBarExtra("Saaa", systemImage: "waveform") {
            HarnessMenu(harness: harness)
        }
    }
}

/// Phase-2 validation harness: records N seconds of a chosen process (both
/// lanes) to two WAVs and reveals them in Finder. Internal tooling — not a
/// shipped user flow.
@MainActor @Observable
final class CaptureHarness {
    enum State {
        case idle
        case recording(target: String, remaining: Int)
        case finished(RecordingResult)
        case failed(String)
    }

    private(set) var state: State = .idle

    struct Target: Identifiable {
        let id: pid_t
        let name: String
        let isPlayingAudio: Bool
    }

    /// Processes the HAL currently knows about, newest audio-active first.
    /// Cheap synchronous property reads — safe to call when the menu opens.
    func availableTargets() -> [Target] {
        let entries = (try? AudioProcessDirectory.snapshot()) ?? []
        var seen = Set<pid_t>()
        return entries.compactMap { entry -> Target? in
            guard entry.pid != ProcessInfo.processInfo.processIdentifier,
                  !seen.contains(entry.pid),
                  let app = NSRunningApplication(processIdentifier: entry.pid),
                  let name = app.localizedName else { return nil }
            seen.insert(entry.pid)
            return Target(id: entry.pid, name: name, isPlayingAudio: entry.isRunningOutput)
        }
        .sorted { ($0.isPlayingAudio ? 0 : 1, $0.name) < ($1.isPlayingAudio ? 0 : 1, $1.name) }
    }

    func record(target: Target, seconds: Int = 10) {
        guard case .idle = state else { return }
        state = .recording(target: target.name, remaining: seconds)
        Task {
            await run(target: target, seconds: seconds)
        }
    }

    private func run(target: Target, seconds: Int) async {
        let stamp = Date().formatted(
            .verbatim(
                "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                timeZone: .current, calendar: .current))
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("Saaa/Harness/\(stamp)", isDirectory: true)

        let session = CaptureSession(
            configuration: CaptureConfiguration(targetPID: target.id, outputDirectory: directory))
        let monitor = Task {
            for await event in session.events {
                switch event {
                case .levels(let levels):
                    // Meter feed proof for Phase 9 — visible in Console.app.
                    if Int(levels.time * 10) % 10 == 0 {
                        print("levels t=\(String(format: "%.1f", levels.time))s mic=\(levels.mic.rmsDecibels)dB sys=\(levels.system.rmsDecibels)dB")
                    }
                case .systemAudioPermissionSuspected:
                    print("warning: system lane is all-zero — System Audio Recording grant suspected missing")
                case .stopped(let reason):
                    print("capture stopped: \(reason)")
                default:
                    print("event: \(event)")
                }
            }
        }
        defer { monitor.cancel() }

        do {
            try await session.start()
            for remaining in stride(from: seconds, through: 1, by: -1) {
                state = .recording(target: target.name, remaining: remaining)
                try await Task.sleep(for: .seconds(1))
                if await session.result != nil { break } // auto-stopped (app quit)
            }
            let result = try await session.stop()
            state = .finished(result)
            NSWorkspace.shared.activateFileViewerSelecting(
                [result.micFileURL, result.systemFileURL])
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func reset() {
        if case .recording = state { return }
        state = .idle
    }
}

struct HarnessMenu: View {
    let harness: CaptureHarness

    var body: some View {
        switch harness.state {
        case .idle:
            Text("Capture harness — record 10 s")
            let targets = harness.availableTargets()
            if targets.isEmpty {
                Text("No audio-capable apps found")
            }
            ForEach(targets) { target in
                Button("\(target.isPlayingAudio ? "🔊 " : "")\(target.name)") {
                    harness.record(target: target)
                }
            }
        case .recording(let target, let remaining):
            Text("Recording \(target)… \(remaining)s")
        case .finished(let result):
            Text("Saved \(String(format: "%.1f", result.duration))s (\(result.backendUsed == .processTap ? "tap" : "SCK"))")
            Button("Record again") { harness.reset() }
        case .failed(let message):
            Text("Failed: \(message)").lineLimit(3)
            Button("Try again") { harness.reset() }
        }
        Divider()
        Button("Quit Saaa") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
