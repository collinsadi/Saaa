import Foundation

/// The secondary auto-stop heuristic: sustained silence on BOTH lanes
/// surfaces a non-blocking "Still recording?" prompt, and only stops if the
/// prompt goes unanswered — never a silent mid-pause cut. Pure logic, fed by
/// the level stream; the hotkey remains authoritative.
public struct SilenceWatchdog: Sendable, Equatable {

    public enum Verdict: Sendable, Equatable {
        /// Nothing to do.
        case quiet
        /// Both lanes silent for `promptAfter` — show the prompt now.
        case prompt
        /// Prompt has been up for `stopAfter` without an answer — stop.
        case timedOut
    }

    /// RMS at/below which a lane counts as silent (≈ -48 dBFS).
    public var silenceThreshold: Float
    /// Continuous both-lane silence before prompting.
    public var promptAfter: TimeInterval
    /// Time the prompt stays up before auto-stop.
    public var stopAfter: TimeInterval

    private var silenceStart: TimeInterval?
    private var promptShownAt: TimeInterval?

    public init(
        silenceThreshold: Float = 0.004,
        promptAfter: TimeInterval = 120,
        stopAfter: TimeInterval = 30
    ) {
        self.silenceThreshold = silenceThreshold
        self.promptAfter = promptAfter
        self.stopAfter = stopAfter
    }

    /// Feed one level sample (both lanes) at time `t` (seconds, monotonic).
    public mutating func feed(mic: Float, system: Float, at t: TimeInterval) -> Verdict {
        let silent = mic <= silenceThreshold && system <= silenceThreshold
        if !silent {
            silenceStart = nil
            promptShownAt = nil
            return .quiet
        }
        if let promptShownAt {
            return t - promptShownAt >= stopAfter ? .timedOut : .prompt
        }
        guard let start = silenceStart else {
            silenceStart = t
            return .quiet
        }
        if t - start >= promptAfter {
            promptShownAt = t
            return .prompt
        }
        return .quiet
    }

    /// The user said "still here" — dismiss and restart the clock.
    public mutating func dismissPrompt() {
        silenceStart = nil
        promptShownAt = nil
    }

    /// Whether the prompt is currently showing.
    public var isPrompting: Bool { promptShownAt != nil }
}
