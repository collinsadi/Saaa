import AgentBridge
import AppKit
import AudioCapture
import AVFoundation
import CalendarContext
import EventKit
import Foundation
import Transcription

/// State + actions for the first-run bootstrap. Every dependency degrades
/// gracefully; the flow can always be finished and re-run from the menu.
@MainActor
@Observable
final class OnboardingModel {

    /// Status semantics drive the chip colors: granted = success, pending =
    /// neutral, action = ember, denied = danger, working = spinner.
    enum StepStatus: Equatable {
        case unknown
        case working(String)
        case granted(String)
        case pending(String)
        case denied(String)
    }

    var step = 0
    let stepCount = 4

    private(set) var micStatus: StepStatus = .unknown
    private(set) var systemAudioStatus: StepStatus = .unknown
    private(set) var calendarStatus: StepStatus = .unknown
    private(set) var modelStatus: StepStatus = .unknown
    private(set) var claudeStatus: StepStatus = .unknown

    private let modelManager = ModelManager()
    private let agents = AgentRegistry.standard
    private let calendarReader = CalendarReader()

    func refresh() {
        micStatus = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted("Granted")
        case .denied, .restricted: .denied("Denied")
        default: .pending("Not asked yet")
        }
        calendarStatus = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted("Granted")
        case .denied, .restricted: .denied("Denied")
        default: .pending("Optional")
        }
        modelStatus = modelManager.isCached(.largeV3Turbo) && modelManager.isCached(.sileroVAD)
            ? .granted("Cached")
            : .pending("1.6 GB, once")
        if case .granted = systemAudioStatus {} else {
            systemAudioStatus = .pending("Manual grant")
        }
    }

    // MARK: - Actions

    func requestMicrophone() {
        micStatus = .working("Asking")
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micStatus = granted ? .granted("Granted") : .denied("Denied")
        }
    }

    /// macOS never volunteers this prompt; the grant is added by hand in the
    /// Settings pane.
    func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ground-truth check: a short silent global-tap capture. Without the
    /// grant the auto-started tap gates the aggregate and zero IO runs.
    /// Caveat: if the app was launched by a script/shell, macOS can
    /// misattribute the check even when the grant is on; the failure copy
    /// tells the user to quit and reopen Saaa themselves.
    func verifySystemAudio() {
        systemAudioStatus = .working("Verifying")
        Task {
            let probeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("saaa-probe-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: probeDir) }
            let session = CaptureSession(configuration: CaptureConfiguration(
                target: .allSystemAudio, outputDirectory: probeDir))
            do {
                try await session.start()
                try? await Task.sleep(for: .milliseconds(2200))
                let result = try await session.stop()
                systemAudioStatus = result.duration > 0.3
                    ? .granted("Verified")
                    : .denied("Blocked")
            } catch {
                systemAudioStatus = .denied("Check failed")
            }
        }
    }

    /// True when the last verification failed, for the recovery hint.
    var systemAudioBlocked: Bool {
        if case .denied = systemAudioStatus { return true }
        return false
    }

    func requestCalendar() {
        calendarStatus = .working("Asking")
        Task {
            let granted = await calendarReader.ensureAccess()
            calendarStatus = granted ? .granted("Granted") : .denied("Denied")
        }
    }

    func downloadModels() {
        modelStatus = .working("Starting")
        Task {
            do {
                _ = try await modelManager.ensure(.sileroVAD)
                _ = try await modelManager.ensure(.largeV3Turbo) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.modelStatus = .working("\(Int(progress.fraction * 100))%")
                    }
                }
                modelStatus = .granted("Cached")
            } catch {
                modelStatus = .denied("Failed")
            }
        }
    }

    /// Checks every supported agent; the step passes when at least one is
    /// installed and signed in. Filing routes between them per project.
    func checkAgents() {
        claudeStatus = .working("Checking")
        Task {
            let installed = agents.installedProviders()
            guard !installed.isEmpty else {
                claudeStatus = .denied("None found")
                return
            }
            var ready: [String] = []
            for provider in installed {
                if await provider.verifyAuthenticated() {
                    ready.append(provider.displayName)
                }
            }
            claudeStatus = ready.isEmpty
                ? .denied("Signed out")
                : .granted(ready.joined(separator: " + "))
        }
    }
}
