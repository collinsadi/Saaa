import Testing
@testable import CallSession

@Suite struct TargetPickerTests {

    private func candidate(
        _ pid: Int32, _ bundleID: String?, playing: Bool
    ) -> TargetPicker.Candidate {
        .init(pid: pid, bundleID: bundleID, name: bundleID ?? "app", isPlayingAudio: playing)
    }

    @Test func prefersAudioActiveConferencingApp() {
        let picked = TargetPicker.pick(from: [
            candidate(1, "com.spotify.client", playing: true),
            candidate(2, "us.zoom.xos", playing: true),
            candidate(3, "com.apple.Safari", playing: false),
        ])
        #expect(picked?.pid == 2)
    }

    @Test func conferencingRankOrdersBrowsersBelowNativeApps() {
        let picked = TargetPicker.pick(from: [
            candidate(1, "com.google.Chrome", playing: true),
            candidate(2, "us.zoom.xos", playing: true),
        ])
        #expect(picked?.pid == 2)
    }

    @Test func fallsBackToAnyAudioActiveApp() {
        let picked = TargetPicker.pick(from: [
            candidate(1, "com.spotify.client", playing: true),
            candidate(2, "us.zoom.xos", playing: false),
        ])
        #expect(picked?.pid == 1)
    }

    @Test func fallsBackToSilentConferencingApp() {
        let picked = TargetPicker.pick(from: [
            candidate(1, "com.spotify.client", playing: false),
            candidate(2, "com.apple.FaceTime", playing: false),
        ])
        #expect(picked?.pid == 2)
    }

    @Test func neverGuessesASilentRandomApp() {
        let picked = TargetPicker.pick(from: [
            candidate(1, "com.spotify.client", playing: false),
            candidate(2, nil, playing: false),
        ])
        #expect(picked == nil)
    }

    @Test func emptyIsNil() {
        #expect(TargetPicker.pick(from: []) == nil)
    }
}
