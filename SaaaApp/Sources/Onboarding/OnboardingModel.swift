import AppKit
import AudioCapture
import AVFoundation
import CalendarContext
import ClaudeBridge
import EventKit
import Foundation
import Transcription

/// State + actions for the first-run bootstrap. Every dependency degrades
/// gracefully — the flow can always be finished and re-run from the menu.
@MainActor
@Observable
final class OnboardingModel {

    enum StepStatus: Equatable {
        case unknown
        case working(String)
        case granted(String)
        case actionNeeded(String)
    }

    var step = 0
    let stepCount = 4

    private(set) var micStatus: StepStatus = .unknown
    private(set) var systemAudioStatus: StepStatus = .unknown
    private(set) var calendarStatus: StepStatus = .unknown
    private(set) var modelStatus: StepStatus = .unknown
    private(set) var claudeStatus: StepStatus = .unknown

    private let modelManager = ModelManager()
    private let claudeCLI = ClaudeCLI()
    private let calendarReader = CalendarReader()

    func refresh() {
        micStatus = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted("Granted")
        case .denied, .restricted: .actionNeeded("Denied — enable in System Settings → Microphone")
        default: .actionNeeded("Not requested yet")
        }
        calendarStatus = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted("Granted")
        case .denied, .restricted: .actionNeeded("Denied — optional, Saaa works without it")
        default: .actionNeeded("Optional — boosts project matching")
        }
        modelStatus = modelManager.isCached(.largeV3Turbo) && modelManager.isCached(.sileroVAD)
            ? .granted("Cached — never downloaded again")
            : .actionNeeded("1.6 GB one-time download")
        if case .granted = systemAudioStatus {} else {
            systemAudioStatus = .actionNeeded("Needs a one-time manual grant")
        }
    }

    // MARK: - Actions

    func requestMicrophone() {
        micStatus = .working("Asking…")
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micStatus = granted
                ? .granted("Granted")
                : .actionNeeded("Denied — enable in System Settings → Microphone")
        }
    }

    /// macOS never volunteers the System Audio Recording prompt for this app;
    /// the grant is added manually in the Settings pane (lower list).
    func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ground-truth verification: a 1.5 s silent global-tap capture. When the
    /// grant is missing the auto-started tap gates the whole aggregate and
    /// zero IO runs → duration 0. Any nonzero duration proves the grant.
    func verifySystemAudio() {
        systemAudioStatus = .working("Verifying…")
        Task {
            let probeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("saaa-probe-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: probeDir) }
            let session = CaptureSession(configuration: CaptureConfiguration(
                target: .allSystemAudio, outputDirectory: probeDir))
            do {
                try await session.start()
                try? await Task.sleep(for: .milliseconds(1500))
                let result = try await session.stop()
                systemAudioStatus = result.duration > 0
                    ? .granted("Granted and verified")
                    : .actionNeeded("Still blocked — check Saaa is in the LOWER list (System Audio Recording Only) and toggled on")
            } catch {
                systemAudioStatus = .actionNeeded("Verification failed: \(String(describing: error))")
            }
        }
    }

    func requestCalendar() {
        calendarStatus = .working("Asking…")
        Task {
            let granted = await calendarReader.ensureAccess()
            calendarStatus = granted
                ? .granted("Granted")
                : .actionNeeded("Denied — optional, Saaa works without it")
        }
    }

    func downloadModels() {
        modelStatus = .working("Starting download…")
        Task {
            do {
                _ = try await modelManager.ensure(.sileroVAD)
                _ = try await modelManager.ensure(.largeV3Turbo) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.modelStatus = .working(
                            "Downloading \(Int(progress.fraction * 100))% of 1.6 GB")
                    }
                }
                modelStatus = .granted("Cached — never downloaded again")
            } catch {
                modelStatus = .actionNeeded("Download failed: \(String(describing: error))")
            }
        }
    }

    func checkClaude() {
        claudeStatus = .working("Checking…")
        Task {
            guard await claudeCLI.locate() != nil else {
                claudeStatus = .actionNeeded(
                    "claude not found — install Claude Code, then re-check")
                return
            }
            do {
                _ = try await claudeCLI.run(ClaudeRunConfiguration(
                    prompt: "Reply with exactly: OK",
                    workingDirectory: FileManager.default.temporaryDirectory,
                    allowedTools: [], maxTurns: 1, timeout: .seconds(60)))
                claudeStatus = .granted("Installed and signed in")
            } catch ClaudeBridgeError.notAuthenticated {
                claudeStatus = .actionNeeded(
                    "Installed but signed out — run `claude` in Terminal and log in")
            } catch {
                claudeStatus = .actionNeeded(
                    "Check failed: \(String(describing: error))")
            }
        }
    }
}
