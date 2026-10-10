import Foundation
import os

/// Live transcription for a call: one SpeechAnalyzer lane per side, fed
/// straight from capture. Events arrive on ``events`` in per-lane order;
/// the session controller applies them to a ``LiveTranscript``.
public final class LiveTranscriber: Sendable {

    public enum Event: Sendable, Equatable {
        /// In-progress words for a lane (replace the previous partial).
        case partial(LiveTranscript.Lane, start: TimeInterval, end: TimeInterval, text: String)
        /// A finalized phrase.
        case final(LiveTranscript.Lane, start: TimeInterval, end: TimeInterval, text: String)
        /// A lane stopped transcribing; the call keeps recording.
        case laneFailed(LiveTranscript.Lane, String)
    }

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "LiveTranscriber")

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let me = SpeechLane(lane: .me)
    private let them = SpeechLane(lane: .them)

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    /// Resolves the language and starts both lanes. Them starts first (it is
    /// what the copilot answers); a Me-lane failure is reported, not thrown.
    @discardableResult
    public func start(locale: Locale, vocabulary: [String] = []) async throws -> SpeechAssets.Resolution {
        guard let resolution = await SpeechAssets.resolve(locale) else {
            throw TranscriptionError.unsupportedLanguage(locale.identifier)
        }
        try await them.start(resolution, live: true, vocabulary: vocabulary, onResult: handler(for: .them))
        do {
            try await me.start(resolution, live: true, vocabulary: vocabulary, onResult: handler(for: .me))
        } catch {
            Self.log.error("me lane unavailable: \(String(describing: error), privacy: .public)")
            continuation.yield(.laneFailed(.me, String(describing: error)))
        }
        return resolution
    }

    /// Feeds one capture chunk to its lane.
    public func append(_ lane: LiveTranscript.Lane, samples: [Int16], startFrame: Int64) {
        switch lane {
        case .me: me.append(samples, startFrame: startFrame)
        case .them: them.append(samples, startFrame: startFrame)
        }
    }

    /// Finalizes both lanes (every word heard becomes final), then ends
    /// the event stream.
    public func finish() async {
        async let meDone: Void = me.finish()
        async let themDone: Void = them.finish()
        _ = await (meDone, themDone)
        continuation.finish()
    }

    /// Stops immediately.
    public func cancel() async {
        await me.cancel()
        await them.cancel()
        continuation.finish()
    }

    private func handler(for lane: LiveTranscript.Lane) -> @Sendable (SpeechLane.Result) -> Void {
        let continuation = self.continuation
        return { result in
            if let error = result.error {
                continuation.yield(.laneFailed(lane, error))
            } else if result.isFinal {
                continuation.yield(.final(lane, start: result.start, end: result.end, text: result.text))
            } else {
                continuation.yield(.partial(lane, start: result.start, end: result.end, text: result.text))
            }
        }
    }
}

extension LiveTranscript {
    /// Applies a transcriber event; returns the commit outcome for finals.
    @discardableResult
    public mutating func apply(_ event: LiveTranscriber.Event) -> CommitOutcome? {
        switch event {
        case .partial(let lane, let start, let end, let text):
            setPartial(lane, start: start, end: end, text: text)
            return nil
        case .final(let lane, let start, let end, let text):
            return commit(lane, start: start, end: end, text: text)
        case .laneFailed:
            return nil
        }
    }
}
