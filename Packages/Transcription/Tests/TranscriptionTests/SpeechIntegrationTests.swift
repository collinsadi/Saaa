import Foundation
import Speech
import Testing
@testable import Transcription

/// Runs Apple's on-device SpeechAnalyzer for real (synthesized speech, no
/// microphone). Installs the en-US model on first run if the system allows.
@Suite("Speech integration", .serialized, .enabled(if: SpeechTranscriber.isAvailable))
struct SpeechIntegrationTests {

    static let locale = Locale(identifier: "en-US")

    static func ensureAssets() async throws -> Bool {
        switch await SpeechAssets.status(for: locale) {
        case .installed:
            return true
        case .needsDownload, .downloading:
            print("SPEECH installing assets for en-US…")
            try await SpeechAssets.install(for: locale) { fraction in
                if Int(fraction * 100) % 25 == 0 { print("SPEECH asset download \(Int(fraction * 100))%") }
            }
            return await SpeechAssets.status(for: locale) == .installed
        case .unsupported:
            print("SPEECH en-US unsupported on this Mac; skipping")
            return false
        }
    }

    @Test func liveLaneTranscribesSynthesizedSpeech() async throws {
        guard try await Self.ensureAssets() else { return }
        let report = try await SpeechSelfTest.run(realtime: true)
        print("SPEECH live:\n\(report)")
        #expect(report.finalCount > 0)
        #expect(report.partialCount > 0)
        #expect(report.wordRecall >= 0.6)
        #expect((report.firstPartialSeconds ?? 99) < 3)
    }

    @Test func fileTranscriptionMatches() async throws {
        guard try await Self.ensureAssets() else { return }
        let samples = try await SpeechSelfTest.synthesize(SpeechSelfTest.sampleText)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saaa-speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMConverter.sourceFormat
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try #require(PCMConverter.makeSourceBuffer(samples))
            try file.write(from: buffer)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let segments = try await FileTranscriber.transcribe(wav: url, lane: .them, locale: Self.locale)
        let text = segments.map(\.text).joined(separator: " ")
        print("SPEECH file (\(start.duration(to: clock.now))): \(text)")
        let expected = TextSimilarity.words(SpeechSelfTest.sampleText)
        let heard = Set(TextSimilarity.words(text))
        let recall = Double(expected.filter { heard.contains($0) }.count) / Double(expected.count)
        #expect(recall >= 0.6)
        #expect(segments.allSatisfy { $0.end >= $0.start })
    }

    @Test func vocabularyContextIsAccepted() async throws {
        guard try await Self.ensureAssets() else { return }
        let transcriber = LiveTranscriber()
        let resolution = try await transcriber.start(locale: Self.locale, vocabulary: ["Saaa", "Anthropic", "Okta"])
        #expect(resolution.engine == .speechTranscriber)
        await transcriber.cancel()
    }
}
