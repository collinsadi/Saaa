import Core
import Testing
@testable import CallSession

@Suite struct SessionStateMachineTests {

    private let transcript = Transcript(
        segments: [TranscriptSegment(speaker: .me, start: 0, end: 1, text: "Hi", confidence: 0.9)],
        language: "en")

    @Test func happyPathHotkeyToDone() {
        var state = SessionState.idle
        for event: SessionEvent in [
            .hotkeyPressed, .captureStarted, .hotkeyPressed,
            .transcriptReady(transcript), .reviewClosed, .reset,
        ] {
            let next = SessionStateMachine.reduce(state, event)
            #expect(next != nil, "\(event) must be valid in \(state)")
            state = next ?? state
        }
        #expect(state == .idle)
    }

    @Test func autoStopReachesProcessing() {
        var state = SessionState.recording
        state = SessionStateMachine.reduce(state, .captureStopped)!
        #expect(state == .processing)
        // A racing duplicate stop (hotkey + auto-stop) is ignored, not fatal.
        #expect(SessionStateMachine.reduce(state, .captureStopped) == nil)
    }

    @Test func hotkeyMashingWhileArmedIsIgnored() {
        #expect(SessionStateMachine.reduce(.armed, .hotkeyPressed) == nil)
    }

    @Test func failuresLandInError() {
        #expect(SessionStateMachine.reduce(.armed, .captureFailed("x")) == .error("x"))
        #expect(SessionStateMachine.reduce(.recording, .captureFailed("x")) == .error("x"))
        #expect(SessionStateMachine.reduce(.processing, .transcriptionFailed("x")) == .error("x"))
    }

    @Test func terminalStatesRestartOnHotkey() {
        #expect(SessionStateMachine.reduce(.done, .hotkeyPressed) == .armed)
        #expect(SessionStateMachine.reduce(.error("x"), .hotkeyPressed) == .armed)
    }

    @Test func invalidEventsAreNil() {
        #expect(SessionStateMachine.reduce(.idle, .captureStopped) == nil)
        #expect(SessionStateMachine.reduce(.idle, .transcriptReady(transcript)) == nil)
        #expect(SessionStateMachine.reduce(.review(transcript), .hotkeyPressed) == nil)
        #expect(SessionStateMachine.reduce(.processing, .hotkeyPressed) == nil)
    }
}
