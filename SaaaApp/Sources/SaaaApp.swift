import AppKit
import SwiftUI
import os
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
/// Phase-4 state (MVP): global hotkey → target resolution → two-lane capture
/// → whisper transcription → Me/Them transcript in a review window. The
/// design-system UI and notch island arrive in Phase 9.
@main
struct SaaaApp: App {
    @State private var harness = CaptureHarness()
    @State private var controller: CallController
    @State private var reviewPresenter: ReviewWindowPresenter
    @State private var hotkey: HotkeyMonitor
    @State private var island: IslandController

    init() {
        let controller = CallController()
        _controller = State(initialValue: controller)

        // Wire the always-on surfaces at launch (not on first menu open):
        // review presenter, global hotkey, and the notch island.
        let presenter = ReviewWindowPresenter()
        controller.onReview = { transcript in
            presenter.show(controller: controller, transcript: transcript)
        }
        _reviewPresenter = State(initialValue: presenter)
        _hotkey = State(initialValue: HotkeyMonitor { controller.toggle() })
        _island = State(initialValue: IslandController(callController: controller))

        // Headless capture self-test (dev tooling): `open Saaa.app --args
        // --selftest [--tap-only|--sck]` records 5 s, writes the usual
        // WAVs + diagnostics.txt, then quits.
        if CommandLine.arguments.contains("--tap-only") {
            AudioCaptureModule.debugTapOnlyComposition = true
        }
        if CommandLine.arguments.contains("--selftest") {
            let harness = harness
            let forceSCK = CommandLine.arguments.contains("--sck")
            Task { @MainActor in
                if forceSCK { harness.forcedBackend = .screenCaptureKit }
                let target: CaptureHarness.Target
                if forceSCK, let running = harness.availableTargets().first(where: { $0.id > 0 }) {
                    target = running
                } else {
                    target = .allSystemAudio
                }
                harness.record(target: target, seconds: 5)
                while !harness.isSettled {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Saaa", systemImage: menuBarIcon) {
            SaaaMenu(controller: controller, harness: harness)
        }
        Settings {
            SaaaSettingsView(controller: controller)
                .saaaThemed()
        }
    }

    /// The always-visible recording indicator (consent-first): the icon
    /// changes whenever capture is live or busy.
    private var menuBarIcon: String {
        switch controller.state {
        case .recording: "record.circle"
        case .armed, .processing: "waveform.badge.magnifyingglass"
        default: "waveform"
        }
    }

}

/// The Phase-4 menu: session state + Start/Stop, the silence prompt, and the
/// capture harness tucked into a debug submenu.
struct SaaaMenu: View {
    let controller: CallController
    let harness: CaptureHarness

    var body: some View {
        statusSection
        Divider()
        Menu("Capture Harness") {
            HarnessMenu(harness: harness)
        }
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Button("Quit Saaa") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var statusSection: some View {
        switch controller.state {
        case .idle, .done:
            Button("Start Recording (⌥⌘R)") { controller.toggle() }
        case .armed:
            Text("Starting…")
        case .recording:
            if let levels = controller.levels {
                Text("Recording \(Duration.seconds(levels.time).formatted(.time(pattern: .minuteSecond)))  Me \(bar(levels.mic.rms))  Them \(bar(levels.system.rms))")
            } else {
                Text("Recording…")
            }
            if controller.silencePromptVisible {
                Button("Still recording? — Keep going") { controller.dismissSilencePrompt() }
            }
            Button("Stop Recording (⌥⌘R)") { controller.toggle() }
        case .processing:
            Text(controller.processingDetail.isEmpty ? "Processing…" : controller.processingDetail)
        case .review:
            Text("Transcript open for review")
        case .error(let message):
            Text("Error: \(message)").lineLimit(4)
            Button("Try Again (⌥⌘R)") { controller.toggle() }
        }
    }

    private func bar(_ rms: Float) -> String {
        let blocks = ["▁", "▂", "▃", "▅", "▆", "█"]
        let level = min(5, Int(rms * 12))
        return blocks[level]
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

    /// True once a run has finished or failed (selftest exit condition).
    var isSettled: Bool {
        switch state {
        case .finished, .failed: true
        case .idle, .recording: false
        }
    }

    struct Target: Identifiable {
        let id: pid_t // -1 = all system audio
        let name: String
        let isPlayingAudio: Bool

        var captureTarget: CaptureTarget {
            id == -1 ? .allSystemAudio : .process(id)
        }

        static let allSystemAudio = Target(
            id: -1, name: "All System Audio (debug)", isPlayingAudio: false)
    }

    /// Pickable apps (helper processes attributed to their app), audio-active
    /// first, plus the global-tap debug entry. Cheap synchronous property
    /// reads — safe to call when the menu opens.
    func availableTargets() -> [Target] {
        let apps = (try? AudioProcessDirectory.appLevelSnapshot(
            excluding: ProcessInfo.processInfo.processIdentifier)) ?? []
        return [.allSystemAudio] + apps.map {
            Target(id: $0.id, name: $0.name, isPlayingAudio: $0.isPlayingAudio)
        }
    }

    /// Debug: force a backend for the next recordings (harness `--sck`).
    var forcedBackend: CaptureBackend?

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
            configuration: CaptureConfiguration(
                target: target.captureTarget, outputDirectory: directory,
                preferredBackend: forcedBackend))
        let log = Logger(subsystem: "dev.collinsadi.saaa", category: "Harness")
        let monitor = Task {
            for await event in session.events {
                switch event {
                case .levels(let levels):
                    // Meter feed proof for Phase 9 — visible in Console.app
                    // (subsystem dev.collinsadi.saaa).
                    if Int(levels.time * 10) % 10 == 0 {
                        log.info("levels t=\(String(format: "%.1f", levels.time))s mic=\(levels.mic.rmsDecibels)dB sys=\(levels.system.rmsDecibels)dB")
                    }
                case .systemAudioPermissionSuspected:
                    log.warning("system lane is all-zero — System Audio Recording grant suspected missing")
                case .stopped(let reason):
                    log.info("capture stopped: \(String(describing: reason), privacy: .public)")
                default:
                    log.info("event: \(String(describing: event), privacy: .public)")
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
