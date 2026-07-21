import Core
import Foundation

/// The authoritative recording lifecycle:
/// `idle → armed → recording → processing → review → done` (+ `error`).
/// The global hotkey is the source of truth; auto-stop is best-effort
/// convenience layered on top.
public enum SessionState: Sendable, Equatable {
    case idle
    /// Hotkey pressed; resolving the conferencing target and starting capture.
    case armed
    case recording
    /// Capture ended; transcribing (details in `CallController.processingDetail`).
    case processing
    /// Transcript ready and shown for review/edit.
    case review(Transcript)
    case done
    case error(String)
}

/// Everything that can advance the lifecycle.
public enum SessionEvent: Sendable, Equatable {
    /// The global hotkey — starts from `idle`, stops from `recording`.
    case hotkeyPressed
    case captureStarted
    case captureFailed(String)
    /// Recording ended (hotkey, auto-stop, or watchdog timeout).
    case captureStopped
    case transcriptReady(Transcript)
    case transcriptionFailed(String)
    /// The user closed the review surface.
    case reviewClosed
    /// Return to idle from `done` / `error`.
    case reset
}

/// Pure transition function — the unit-tested heart of the lifecycle.
public enum SessionStateMachine {

    /// Returns the next state, or `nil` when the event is invalid in the
    /// current state (callers ignore invalid events rather than crashing —
    /// hotkey mashing and racing auto-stops must be harmless).
    public static func reduce(_ state: SessionState, _ event: SessionEvent) -> SessionState? {
        switch (state, event) {
        case (.idle, .hotkeyPressed):
            return .armed
        case (.armed, .captureStarted):
            return .recording
        case (.armed, .captureFailed(let message)):
            return .error(message)
        case (.armed, .hotkeyPressed):
            return nil // still resolving; ignore mashing
        case (.recording, .hotkeyPressed),
             (.recording, .captureStopped):
            return .processing
        case (.recording, .captureFailed(let message)):
            return .error(message)
        case (.processing, .transcriptReady(let transcript)):
            return .review(transcript)
        case (.processing, .transcriptionFailed(let message)):
            return .error(message)
        case (.processing, .captureStopped):
            return nil // duplicate stop signals are harmless
        case (.review, .reviewClosed):
            return .done
        case (.done, .reset), (.error, .reset):
            return .idle
        case (.done, .hotkeyPressed), (.error, .hotkeyPressed):
            // Convenience: a hotkey press from a terminal state starts fresh.
            return .armed
        default:
            return nil
        }
    }
}
