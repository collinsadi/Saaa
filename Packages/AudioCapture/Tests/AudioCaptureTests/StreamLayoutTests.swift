import Foundation
import Testing
@testable import AudioCapture

@Suite struct StreamLayoutTests {

    private func info(_ channels: Int, _ rate: Double = 48_000) -> StreamLayout.StreamInfo {
        .init(channels: channels, sampleRate: rate, isFloat: true)
    }

    @Test func monoMicBeforeStereoTap() throws {
        // Built-in mic (1ch) + stereo tap — the common case.
        let result = try StreamLayout.resolve(
            inputStreams: [info(1), info(2)], tapChannels: 2)
        #expect(result.micIndex == 0)
        #expect(result.tapIndex == 1)
    }

    @Test func stereoMicBeforeStereoTapUsesPosition() throws {
        // 2ch USB mic + 2ch tap: channel counts can't disambiguate, but with
        // exactly two streams position can (sub-devices precede taps).
        let result = try StreamLayout.resolve(
            inputStreams: [info(2), info(2)], tapChannels: 2)
        #expect(result.micIndex == 0)
        #expect(result.tapIndex == 1)
    }

    @Test func multiStreamMicKeepsFirstStream() throws {
        // Combo device contributing two mic-side streams before the tap.
        let result = try StreamLayout.resolve(
            inputStreams: [info(1), info(1), info(2)], tapChannels: 2)
        #expect(result.micIndex == 0)
        #expect(result.tapIndex == 2)
    }

    @Test func singleStreamIsAmbiguous() {
        #expect(throws: CaptureError.self) {
            try StreamLayout.resolve(inputStreams: [info(2)], tapChannels: 2)
        }
    }

    @Test func emptyIsAmbiguous() {
        #expect(throws: CaptureError.self) {
            try StreamLayout.resolve(inputStreams: [], tapChannels: 2)
        }
    }

    @Test func allStreamsMatchingTapWithThreeStreamsIsAmbiguous() {
        // Three 2ch streams, tap 2ch: trailing run swallows everything and
        // position alone can't attribute — must refuse to guess.
        #expect(throws: CaptureError.self) {
            try StreamLayout.resolve(
                inputStreams: [info(2), info(2), info(2)], tapChannels: 2)
        }
    }
}
