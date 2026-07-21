import Testing
@testable import CallSession

@Suite struct SilenceWatchdogTests {

    @Test func staysQuietDuringNormalConversation() {
        var watchdog = SilenceWatchdog(promptAfter: 120, stopAfter: 30)
        for t in stride(from: 0.0, to: 300, by: 0.1) {
            // Alternating speech: never both-silent long enough.
            let talking = Int(t) % 20 < 15
            let verdict = watchdog.feed(
                mic: talking ? 0.2 : 0.001, system: 0.001, at: t)
            #expect(verdict == .quiet)
        }
    }

    @Test func promptsAfterSustainedSilenceThenTimesOut() {
        var watchdog = SilenceWatchdog(promptAfter: 120, stopAfter: 30)
        var verdicts: [SilenceWatchdog.Verdict] = []
        for t in stride(from: 0.0, to: 160, by: 1.0) {
            verdicts.append(watchdog.feed(mic: 0.0, system: 0.0, at: t))
        }
        #expect(verdicts[119] == .quiet)
        #expect(verdicts[120] == .prompt)
        #expect(verdicts[149] == .prompt)
        #expect(verdicts[150] == .timedOut)
    }

    @Test func speechCancelsThePrompt() {
        var watchdog = SilenceWatchdog(promptAfter: 10, stopAfter: 30)
        for t in stride(from: 0.0, to: 11, by: 1.0) {
            _ = watchdog.feed(mic: 0, system: 0, at: t)
        }
        #expect(watchdog.isPrompting)
        #expect(watchdog.feed(mic: 0.3, system: 0, at: 12) == .quiet)
        #expect(!watchdog.isPrompting)
        // Clock restarts from scratch.
        #expect(watchdog.feed(mic: 0, system: 0, at: 13) == .quiet)
        #expect(watchdog.feed(mic: 0, system: 0, at: 22) == .quiet)
        #expect(watchdog.feed(mic: 0, system: 0, at: 23.5) == .prompt)
    }

    @Test func dismissRestartsTheClock() {
        var watchdog = SilenceWatchdog(promptAfter: 10, stopAfter: 30)
        for t in stride(from: 0.0, to: 11, by: 1.0) {
            _ = watchdog.feed(mic: 0, system: 0, at: t)
        }
        #expect(watchdog.isPrompting)
        watchdog.dismissPrompt()
        #expect(watchdog.feed(mic: 0, system: 0, at: 12) == .quiet)
        #expect(watchdog.feed(mic: 0, system: 0, at: 21) == .quiet)
        #expect(watchdog.feed(mic: 0, system: 0, at: 22.5) == .prompt)
    }

    @Test func oneLoudLaneIsNotSilence() {
        var watchdog = SilenceWatchdog(promptAfter: 5, stopAfter: 5)
        for t in stride(from: 0.0, to: 30, by: 1.0) {
            #expect(watchdog.feed(mic: 0.0, system: 0.2, at: t) == .quiet)
        }
    }
}
