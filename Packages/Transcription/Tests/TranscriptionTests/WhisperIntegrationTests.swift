import Foundation
import Testing
@testable import Transcription

/// Real-inference integration test, opt-in via `SAAA_WHISPER_SMOKE=1`
/// (downloads ~78 MB of test fixtures on first run; cached afterwards).
/// Proves the whole bridge: model load, whisper_full with integrated Silero
/// VAD, initial prompt, segment + timestamp + language extraction.
@Suite struct WhisperIntegrationTests {

    static let enabled = ProcessInfo.processInfo.environment["SAAA_WHISPER_SMOKE"] == "1"

    private static let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("saaa-whisper-fixtures", isDirectory: true)

    private func fixture(_ name: String, from url: String) async throws -> URL {
        let destination = Self.fixtureDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(
            at: Self.fixtureDirectory, withIntermediateDirectories: true)
        let (temp, response) = try await URLSession.shared.download(from: URL(string: url)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    @Test(.enabled(if: enabled)) func transcribesRealSpeech() async throws {
        let model = try await fixture(
            "ggml-tiny.en.bin",
            from: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")
        let vad = try await fixture(
            "ggml-silero-v5.1.2.bin",
            from: WhisperModel.sileroVAD.downloadURL.absoluteString)
        let audio = try await fixture(
            "jfk.wav",
            from: "https://github.com/ggml-org/whisper.cpp/raw/master/samples/jfk.wav")

        let transcriber = try WhisperTranscriber(modelPath: model, vadModelPath: vad)
        let result = try await transcriber.transcribe(
            wavFile: audio, initialPrompt: VocabularyBias.initialPrompt(terms: ["JFK"]))

        #expect(!result.segments.isEmpty)
        let text = result.segments.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("country"))
        #expect(result.language == "en")
        let last = try #require(result.segments.last)
        #expect(last.end > 5) // jfk.wav is ~11 s of speech
        #expect(last.confidence > 0.5)
    }
}
