import Core
import Testing
@testable import Transcription

@Suite struct TranscriptMergerTests {

    private func seg(_ start: Double, _ end: Double, _ text: String) -> ChannelSegment {
        ChannelSegment(start: start, end: end, text: text, confidence: 0.9)
    }

    @Test func interleavesByStartTime() {
        let mic = ChannelTranscription(
            segments: [seg(0, 2, "Hi there"), seg(5, 7, "Sounds good")], language: "en")
        let system = ChannelTranscription(
            segments: [seg(2.5, 4.5, "Hello, shall we start?")], language: "en")
        let transcript = TranscriptMerger.merge(mic: mic, system: system)

        #expect(transcript.segments.count == 3)
        #expect(transcript.segments[0].speaker == .me)
        #expect(transcript.segments[1].speaker == .them(label: nil))
        #expect(transcript.segments[2].speaker == .me)
        #expect(transcript.attributedText == """
        Me: Hi there
        Them: Hello, shall we start?
        Me: Sounds good
        """)
    }

    @Test func tieBreaksRemoteFirst() {
        let mic = ChannelTranscription(segments: [seg(1, 3, "Right")], language: "en")
        let system = ChannelTranscription(segments: [seg(1, 2, "So anyway")], language: "en")
        let transcript = TranscriptMerger.merge(mic: mic, system: system)
        #expect(transcript.segments[0].speaker == .them(label: nil))
        #expect(transcript.segments[1].speaker == .me)
    }

    @Test func emptyLanesProduceEmptyTranscript() {
        let empty = ChannelTranscription(segments: [], language: "en")
        let transcript = TranscriptMerger.merge(mic: empty, system: empty)
        #expect(transcript.segments.isEmpty)
        #expect(transcript.attributedText.isEmpty)
    }

    @Test func languagePrefersMicUnlessMicIsEmpty() {
        let mic = ChannelTranscription(segments: [seg(0, 1, "Hallo")], language: "de")
        let system = ChannelTranscription(segments: [seg(1, 2, "Hi")], language: "en")
        #expect(TranscriptMerger.merge(mic: mic, system: system).language == "de")

        let emptyMic = ChannelTranscription(segments: [], language: "auto")
        #expect(TranscriptMerger.merge(mic: emptyMic, system: system).language == "en")
    }

    @Test func oneSidedCallStillOrders() {
        let mic = ChannelTranscription(segments: [], language: "en")
        let system = ChannelTranscription(
            segments: [seg(3, 4, "B"), seg(0, 1, "A")], language: "en")
        let transcript = TranscriptMerger.merge(mic: mic, system: system)
        #expect(transcript.segments.map(\.text) == ["A", "B"])
    }
}
