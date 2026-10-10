import AnthropicKit
import Copilot
import Core
import Foundation
import Transcription

/// The whole live brain without a microphone: synthesized speech → live
/// SpeechAnalyzer transcript → copilot answer from Claude. Run from the app
/// (`--selftest-pipeline`) to measure word-to-answer latency on this Mac.
public enum PipelineSelfTest {

    public static func run(client: AnthropicClient = .keychain()) async throws -> String {
        var report: [String] = []
        let question = "Hi, thanks for making time. Quick question before we start: how does your pricing work for a team of forty people?"
        let samples = try await SpeechSelfTest.synthesize(question)
        let transcriber = LiveTranscriber()
        let resolution = try await transcriber.start(locale: Locale(identifier: "en-US"), vocabulary: ["Saaa"])
        report.append("engine: \(resolution.engine.rawValue) \(resolution.locale.identifier)")

        let clock = ContinuousClock()
        let started = clock.now
        let consumer = Task { () -> (LiveTranscript, Duration?) in
            var transcript = LiveTranscript()
            var firstFinal: Duration?
            for await event in transcriber.events {
                if case .final = event, firstFinal == nil { firstFinal = started.duration(to: clock.now) }
                transcript.apply(event)
            }
            return (transcript, firstFinal)
        }
        let padded = samples + [Int16](repeating: 0, count: 16_000)
        var frame = 0
        while frame < padded.count {
            let end = min(frame + 1_600, padded.count)
            transcriber.append(.them, samples: Array(padded[frame..<end]), startFrame: Int64(frame))
            frame = end
            try await Task.sleep(for: .milliseconds(100))
        }
        let speechEnded = clock.now
        await transcriber.finish()
        let (transcript, firstFinal) = await consumer.value
        report.append("heard: \(transcript.plainText)")
        report.append("first final after: \(firstFinal.map { "\($0)" } ?? "none"); finalize took \(speechEnded.duration(to: clock.now))")

        var playbook = Playbook.sales
        playbook.knowledge = [KnowledgeItem(name: "Pricing.md", text: "Team plan: $24 per seat per month, billed annually. 10% off above 25 seats.")]
        let composer = PromptComposer(playbook: playbook, context: SessionContext(title: "Acme intro", goal: "Book a pilot"))
        let detected = transcript.entries.last.flatMap { QuestionDetector.extractQuestion($0.segment.text) }
        report.append("detected question: \(detected ?? "none")")
        let request = composer.liveRequest(
            .action(StandardActions.answer, focus: detected), transcript: transcript,
            now: transcript.duration + 1, recent: [], model: ModelRole.live.modelID())
        let asked = clock.now
        var answer = ""
        var result: StreamResult?
        for try await event in client.streamText(request, deadline: .seconds(45)) {
            switch event {
            case .text(let piece): answer += piece
            case .finished(let finished): result = finished
            case .started: break
            }
        }
        report.append("answer (\(result?.model ?? "?"), first token \(result?.timeToFirstToken.map { "\($0)" } ?? "?"), total \(asked.duration(to: clock.now))):")
        report.append(answer)
        if let usage = result?.usage {
            report.append("usage: in \(usage.inputTokens) cache-read \(usage.cacheReadTokens) cache-write \(usage.cacheWrite5mTokens) out \(usage.outputTokens) · \(UsageLedger.format(ModelCatalog.cost(of: usage, modelID: result?.model ?? "")))")
        }
        return report.joined(separator: "\n")
    }
}
