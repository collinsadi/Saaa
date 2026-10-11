import AnthropicKit
import AppKit
import AudioCapture
import AVFoundation
import CalendarContext
import CallSession
import EventKit
import Foundation
import Observation
import Transcription

/// Claude API key entry, verification and storage, shared by setup and
/// Settings. A key reaches the Keychain only after Claude accepts it.
@MainActor
@Observable
final class ClaudeKeySetup {
    enum State: Equatable {
        case idle
        case checking
        case verified(String)
        case failed(String)
    }

    var entry = ""
    private(set) var state: State = .idle
    /// The saved key, redacted for display.
    private(set) var storedKey: String?

    init() {
        storedKey = KeychainKeyStore.shared.load().map(KeychainKeyStore.redacted)
    }

    var hasStoredKey: Bool { storedKey != nil }

    var canSubmit: Bool {
        state != .checking && KeychainKeyStore.looksLikeAPIKey(entry)
    }

    var isChecking: Bool { state == .checking }

    var isVerified: Bool {
        if case .verified = state { return true }
        return false
    }

    /// Checks the pasted key with a tiny request on the live model, then saves it.
    func verifyAndSave(onSaved: @escaping @MainActor () -> Void = {}) {
        let key = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeychainKeyStore.looksLikeAPIKey(key) else {
            state = .failed("That doesn't look like a Claude API key. Keys start with sk-ant-.")
            return
        }
        state = .checking
        Task {
            do {
                let check = try await AnthropicClient(apiKey: key).verifyKey(model: ModelRole.live.modelID())
                try KeychainKeyStore.shared.save(key)
                entry = ""
                storedKey = KeychainKeyStore.redacted(key)
                state = .verified(Self.describe(check))
                onSaved()
            } catch {
                state = .failed(Self.message(for: error))
            }
        }
    }

    /// Re-checks the saved key against the live model.
    func testStored() {
        state = .checking
        Task {
            do {
                let check = try await AnthropicClient.keychain().verifyKey(model: ModelRole.live.modelID())
                state = .verified(Self.describe(check))
            } catch {
                state = .failed(Self.message(for: error))
            }
        }
    }

    func remove() {
        try? KeychainKeyStore.shared.delete()
        storedKey = nil
        state = .idle
    }

    private static func describe(_ check: KeyCheck) -> String {
        let name = ModelCatalog.model(id: check.model)?.shortName ?? check.model
        return "Connected. \(name) answered in \(seconds(check.latency))."
    }

    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? AnthropicError {
            if case .unauthorized = error {
                return "Claude didn't accept that key. Check that you copied all of it."
            }
            return error.userMessage
        }
        if error is KeychainKeyStore.StoreError {
            return "The key couldn't be saved to your Keychain."
        }
        return error.localizedDescription
    }
}

/// The on-device speech model for the transcription language.
@MainActor
@Observable
final class SpeechSetup {
    private(set) var status: SpeechAssets.Status?
    /// 0...1 while downloading.
    private(set) var progress: Double?
    private(set) var failure: String?
    private(set) var languages: [Locale] = []

    var languageName: String {
        let locale = SaaaSettings.locale()
        return Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    func refresh() async {
        status = await SpeechAssets.status(for: SaaaSettings.locale())
    }

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        languages = await SpeechAssets.supportedLanguages()
    }

    func install() {
        guard progress == nil else { return }
        progress = 0
        failure = nil
        let locale = SaaaSettings.locale()
        let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        Task {
            for await value in updates {
                progress = value
            }
        }
        Task {
            do {
                try await SpeechAssets.install(for: locale) { value in
                    continuation.yield(value)
                }
            } catch {
                failure = "The speech model didn't download. Check your connection and try again."
            }
            continuation.finish()
            progress = nil
            await refresh()
        }
    }
}

/// Microphone, system audio and calendar access, with honest checks.
@MainActor
@Observable
final class PermissionCenter {
    enum Status: Equatable {
        case notAsked
        case checking
        case granted
        case denied
        /// System audio has no status API: unknown until a check runs.
        case unverified
    }

    private(set) var microphone: Status = .notAsked
    private(set) var systemAudio: Status = .unverified
    private(set) var calendar: Status = .notAsked

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notAsked
        }
        calendar = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied, .restricted, .writeOnly: .denied
        default: .notAsked
        }
    }

    func requestMicrophone() {
        microphone = .checking
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = granted ? .granted : .denied
        }
    }

    /// Ground truth for system audio: a two-second capture of everything
    /// playing. Without the grant macOS gates the tap and no audio arrives.
    /// The first check is also what makes macOS ask.
    func verifySystemAudio() {
        systemAudio = .checking
        Task {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("saaa-probe-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = CaptureSession(configuration: CaptureConfiguration(
                target: .allSystemAudio, outputDirectory: directory))
            do {
                try await session.start()
                try? await Task.sleep(for: .milliseconds(2200))
                let result = try await session.stop()
                systemAudio = result.duration > 0.3 ? .granted : .denied
            } catch CaptureError.microphonePermissionDenied {
                microphone = .denied
                systemAudio = .unverified
            } catch {
                systemAudio = .denied
            }
        }
    }

    func requestCalendar() {
        calendar = .checking
        Task {
            let granted = await CalendarReader().ensureAccess()
            calendar = granted ? .granted : .denied
        }
    }

    func openMicrophoneSettings() {
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openSystemAudioSettings() {
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openCalendarSettings() {
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
