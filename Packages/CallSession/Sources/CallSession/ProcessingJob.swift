import ClaudeBridge
import Core
import Foundation
import Matching

/// One stopped session in the background processing queue. Recording ends
/// enqueue instantly, the state machine frees for the next call, and the
/// serial worker takes jobs through transcribe -> match -> judge -> seal.
public struct ProcessingJob: Identifiable, Sendable {

    public enum Status: Equatable, Sendable {
        case waiting
        case running(String)
        /// Processed and sealed; review not yet opened.
        case ready
        case reviewing
        case done
        case failed(String)
    }

    public let id = UUID()
    /// Short human label (calendar title, import filename, or time).
    public let title: String
    public let startedAt: Date
    public var status: Status = .waiting

    // Pipeline inputs.
    let micWAV: URL?
    let systemWAV: URL
    let duration: TimeInterval
    let directory: URL
    let calendar: Core.CalendarContext?

    /// Everything review and write-back need, once processed.
    public var context: ReviewContext?
}

/// Job-scoped review payload: the review window and the confirmed
/// write-back operate on THIS, never on controller-global session state,
/// so any queued call can be reviewed at any time.
public struct ReviewContext: Identifiable, Sendable {
    /// Doubles as the session store record id.
    public let id: UUID
    public let transcript: Transcript
    public let matches: [ScoredCandidate]
    public let judgment: CallJudgment?
    public let sessionDirectory: URL
    /// Learning inputs for a confirmed write-back (issue #7).
    public let meetingTitle: String?
    public let transcriptVector: [Double]?
}

/// Non-reentrant async mutex. The whisper context is one shared resource
/// used by both the Live Assist streamer and the queue worker; actor
/// reentrancy alone does not guarantee the two never interleave.
public actor AsyncGate {

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` holding the gate, releasing on any exit.
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}
