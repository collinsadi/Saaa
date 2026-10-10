import CoreMedia
import Foundation
import Speech

/// Which on-device engine serves a language, and whether its model is on
/// this Mac. SpeechTranscriber is the long-form conversational model;
/// DictationTranscriber covers the locales it lacks.
public enum SpeechAssets {

    public enum Engine: String, Sendable, Codable {
        case speechTranscriber
        case dictation
    }

    public struct Resolution: Sendable, Equatable {
        public let locale: Locale
        public let engine: Engine
    }

    public enum Status: Sendable, Equatable {
        case unsupported
        case needsDownload
        case downloading
        case installed
    }

    /// The best engine + exact supported locale for `locale`, or nil.
    public static func resolve(_ locale: Locale) async -> Resolution? {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return Resolution(locale: supported, engine: .speechTranscriber)
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return Resolution(locale: supported, engine: .dictation)
        }
        return nil
    }

    /// Asset status for `locale` on its best engine.
    public static func status(for locale: Locale) async -> Status {
        guard let resolution = await resolve(locale) else { return .unsupported }
        let module = TranscriberModule.make(resolution, live: true)
        switch await AssetInventory.status(forModules: [module.speechModule]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Downloads and installs the model for `locale` (no-op when present).
    /// `progress` reports 0...1 while the system downloads.
    public static func install(
        for locale: Locale,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let resolution = await resolve(locale) else {
            throw TranscriptionError.unsupportedLanguage(locale.identifier)
        }
        let module = TranscriberModule.make(resolution, live: true)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module.speechModule]) else {
            progress?(1)
            return
        }
        let reporter = Task {
            while !Task.isCancelled {
                progress?(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
        progress?(1)
    }

    /// Languages offered in Settings, de-duplicated by identifier.
    public static func supportedLanguages() async -> [Locale] {
        var seen = Set<String>()
        var result: [Locale] = []
        let speech = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        for locale in speech + dictation {
            if seen.insert(locale.identifier).inserted { result.append(locale) }
        }
        return result.sorted {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < ($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case unsupportedLanguage(String)
    case engineUnavailable(String)
    case audioUnreadable(String)
}

/// The concrete Speech module behind a lane.
enum TranscriberModule: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    static func make(_ resolution: SpeechAssets.Resolution, live: Bool) -> TranscriberModule {
        switch resolution.engine {
        case .speechTranscriber:
            .speech(SpeechTranscriber(
                locale: resolution.locale,
                preset: live ? .timeIndexedProgressiveTranscription : .transcription))
        case .dictation:
            .dictation(DictationTranscriber(
                locale: resolution.locale,
                preset: live ? .progressiveLongDictation : .longDictation))
        }
    }

    var speechModule: any SpeechModule {
        switch self {
        case .speech(let module): module
        case .dictation(let module): module
        }
    }

    /// Consumes the module's result sequence until the analyzer finishes.
    func consumeResults(_ onResult: @escaping @Sendable (SpeechLane.Result) -> Void) -> Task<Void, Never> {
        switch self {
        case .speech(let module):
            return Task {
                do {
                    for try await result in module.results {
                        onResult(SpeechLane.Result(
                            start: result.range.start.seconds,
                            end: CMTimeRangeGetEnd(result.range).seconds,
                            text: String(result.text.characters),
                            isFinal: result.isFinal))
                    }
                } catch {
                    onResult(SpeechLane.Result.failure(String(describing: error)))
                }
            }
        case .dictation(let module):
            return Task {
                do {
                    for try await result in module.results {
                        onResult(SpeechLane.Result(
                            start: result.range.start.seconds,
                            end: CMTimeRangeGetEnd(result.range).seconds,
                            text: String(result.text.characters),
                            isFinal: result.isFinal))
                    }
                } catch {
                    onResult(SpeechLane.Result.failure(String(describing: error)))
                }
            }
        }
    }
}
