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

/// Connecting Claude through the Saaa relay, shared by setup and Settings.
/// The pasted key goes to the relay once: it checks the key with Anthropic,
/// seals it and hands back this Mac's access token. Nothing touches the
/// Keychain, so there's never a password prompt.
@MainActor
@Observable
final class ClaudeConnectionSetup {
    enum State: Equatable {
        case idle
        case checking
        case verified(String)
        case failed(String)
    }

    var entry = ""
    /// An invite code (SAAA-…) for a hosted account, or a link code from
    /// another Mac on one.
    var inviteEntry = ""
    /// The relay address; Settings can point it at a self-hosted relay.
    var serverText: String
    private(set) var state: State = .idle
    private(set) var connection: RelayConnection?
    /// This month's use on the server; nil until loaded or when the server
    /// is too old to report it.
    private(set) var usage: SaaaRelay.Usage?
    /// A code for adding another Mac to this hosted account.
    private(set) var linkCode: (code: String, expires: Date)?

    @ObservationIgnored private let store: RelayConnectionStore

    init(store: RelayConnectionStore = .shared) {
        self.store = store
        let current = store.load()
        connection = current
        serverText = (current?.server ?? SaaaRelay.defaultServer)?.absoluteString ?? ""
    }

    var isConnected: Bool { connection != nil }
    var isHosted: Bool { connection?.isHosted == true }

    var canJoin: Bool {
        state != .checking && !inviteEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && serverURL != nil
    }
    var isChecking: Bool { state == .checking }
    var isVerified: Bool {
        if case .verified = state { return true }
        return false
    }

    var serverHost: String {
        connection?.server.host() ?? serverURL?.host() ?? serverText
    }

    var canSubmit: Bool {
        state != .checking && ClaudeAPIKey.looksValid(entry) && serverURL != nil
    }

    private var serverURL: URL? {
        guard let url = URL(string: serverText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// Sends the key to the relay (or replaces it on the current account),
    /// saves this Mac's token, then times one tiny request end to end.
    func connect(onConnected: @escaping @MainActor () -> Void = {}) {
        let key = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeAPIKey.looksValid(key) else {
            state = .failed("That doesn't look like a Claude API key. Keys start with sk-ant-.")
            return
        }
        guard let server = serverURL else {
            state = .failed(serverText.isEmpty
                ? "Enter your Saaa server's address in Settings first."
                : "The server address needs to start with https://.")
            return
        }
        state = .checking
        let label = Host.current().localizedName ?? "Mac"
        let store = self.store
        let existing = connection
        Task {
            do {
                let relay = SaaaRelay(server: server)
                if let existing, existing.server == server {
                    let account = try await relay.replaceKey(token: existing.token, apiKey: key)
                    var updated = existing
                    updated.keyHint = account.keyHint
                    try store.save(updated)
                    connection = updated
                } else {
                    let registration = try await relay.register(apiKey: key, label: label)
                    try store.save(registration.connection)
                    connection = registration.connection
                }
                entry = ""
                onConnected()
            } catch {
                state = .failed(Self.message(for: error, host: server.host() ?? server.absoluteString))
                return
            }
            do {
                let check = try await AnthropicClient.relay(store).verifyKey(model: ModelRole.live.modelID())
                state = .verified(Self.describe(check))
            } catch {
                state = .failed("Connected, but a test answer failed: \(Self.message(for: error, host: server.host() ?? ""))")
            }
        }
    }

    /// Opens a hosted account with an invite code, or joins one with a link
    /// code from another Mac, then times one tiny request end to end.
    func join(onConnected: @escaping @MainActor () -> Void = {}) {
        let code = inviteEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        guard let server = serverURL else {
            state = .failed(serverText.isEmpty
                ? "Enter your Saaa server's address in Settings first."
                : "The server address needs to start with https://.")
            return
        }
        state = .checking
        let label = Host.current().localizedName ?? "Mac"
        let store = self.store
        Task {
            do {
                let relay = SaaaRelay(server: server)
                let registration = code.uppercased().hasPrefix("SAAA")
                    ? try await relay.joinHosted(inviteCode: code, label: label)
                    : try await relay.joinHosted(linkCode: code, label: label)
                try store.save(registration.connection)
                connection = registration.connection
                inviteEntry = ""
                onConnected()
            } catch {
                state = .failed(Self.message(for: error, host: server.host() ?? server.absoluteString))
                return
            }
            refreshUsage()
            do {
                let check = try await AnthropicClient.relay(store).verifyKey(model: ModelRole.live.modelID())
                state = .verified(Self.describe(check))
            } catch {
                state = .failed("Joined, but a test answer failed: \(Self.message(for: error, host: server.host() ?? ""))")
            }
        }
    }

    /// Loads this month's use from the server. Older servers don't report
    /// it; then nothing shows.
    func refreshUsage() {
        guard let current = connection else {
            usage = nil
            return
        }
        Task {
            usage = try? await SaaaRelay(server: current.server).usage(token: current.token)
        }
    }

    /// A code that adds another Mac to this hosted account.
    func makeLinkCode() {
        guard let current = connection, current.isHosted else { return }
        Task {
            do {
                let code = try await SaaaRelay(server: current.server).linkCode(token: current.token)
                linkCode = (code.linkCode, Date.now.addingTimeInterval(TimeInterval(code.expiresIn)))
            } catch {
                state = .failed(Self.message(for: error, host: current.server.host() ?? ""))
            }
        }
    }

    /// Re-checks the connection end to end.
    func test() {
        state = .checking
        let store = self.store
        let host = serverHost
        Task {
            do {
                let check = try await AnthropicClient.relay(store).verifyKey(model: ModelRole.live.modelID())
                state = .verified(Self.describe(check))
            } catch {
                state = .failed(Self.message(for: error, host: host))
            }
        }
    }

    /// Signs this Mac out. The key stays on the server for your other devices.
    func disconnect(onDone: @escaping @MainActor () -> Void = {}) {
        guard let current = connection else { return }
        let store = self.store
        Task {
            try? await SaaaRelay(server: current.server).signOut(token: current.token)
            store.delete()
            connection = nil
            usage = nil
            linkCode = nil
            state = .idle
            onDone()
        }
    }

    /// Deletes the key from the server and signs every device out.
    func deleteFromServer(onDone: @escaping @MainActor () -> Void = {}) {
        guard let current = connection else { return }
        state = .checking
        let store = self.store
        Task {
            do {
                try await SaaaRelay(server: current.server).deleteAccount(token: current.token)
            } catch AnthropicError.relayUnauthorized {
                // Already gone on the server.
            } catch {
                state = .failed(Self.message(for: error, host: current.server.host() ?? ""))
                return
            }
            store.delete()
            connection = nil
            usage = nil
            linkCode = nil
            state = .idle
            onDone()
        }
    }

    private static func describe(_ check: KeyCheck) -> String {
        let name = ModelCatalog.model(id: check.model)?.shortName ?? check.model
        return "Connected. \(name) answered in \(seconds(check.latency))."
    }

    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }

    private static func message(for error: Error, host: String) -> String {
        guard let error = error as? AnthropicError else { return error.localizedDescription }
        switch error {
        case .unauthorized(let message) where message.contains("Anthropic"):
            return message
        case .unauthorized:
            return "Anthropic didn't accept that key. Check that you copied all of it."
        case .network:
            return "Couldn't reach your Saaa server (\(host)). Check your connection."
        case .invalidRequest(let message), .permissionDenied(let message), .server(_, let message):
            return message
        default:
            return error.userMessage
        }
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
