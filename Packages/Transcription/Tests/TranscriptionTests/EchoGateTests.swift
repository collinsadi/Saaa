import Foundation
import Testing
@testable import Transcription

@Suite("Echo gate")
struct EchoGateTests {

    /// 100 ms of a sine at `frequency` with peak `amplitude` (0...1), starting at `frame`.
    static func tone(_ frequency: Double, amplitude: Double, frame: Int64, count: Int = 1_600) -> [Int16] {
        (0..<count).map { offset in
            let t = Double(frame + Int64(offset)) / 16_000
            return Int16((sin(2 * .pi * frequency * t) * amplitude * 32_767).rounded())
        }
    }

    static func silence(_ count: Int = 1_600) -> [Int16] {
        [Int16](repeating: 0, count: count)
    }

    /// Feeds aligned 100 ms chunks (mic first, like the capture drain) and
    /// collects what the Me recognizer would hear.
    static func run(
        _ gate: inout EchoGate, from start: Int, to end: Int,
        mic: (Int64) -> [Int16], system: (Int64) -> [Int16]?
    ) -> [EchoGate.Chunk] {
        var out: [EchoGate.Chunk] = []
        for index in start..<end {
            let frame = Int64(index) * EchoGate.frameLength
            out += gate.addMic(mic(frame), startFrame: frame)
            if let samples = system(frame) {
                out += gate.addSystem(samples, startFrame: frame)
            }
        }
        return out
    }

    static func joined(_ chunks: [EchoGate.Chunk]) -> [Int16] {
        chunks.flatMap(\.samples)
    }

    @Test func passesMicStraightThroughWithoutSystemAudio() {
        var gate = EchoGate()
        let input = Self.tone(220, amplitude: 0.3, frame: 0)
        let out = gate.addMic(input, startFrame: 0)
        #expect(out == [EchoGate.Chunk(samples: input, startFrame: 0)])
    }

    @Test func silencesEchoOnceTheCouplingIsLearned() {
        var gate = EchoGate()
        let chunks = Self.run(
            &gate, from: 0, to: 60,
            mic: { Self.tone(440, amplitude: 0.05, frame: $0) },
            system: { Self.tone(440, amplitude: 0.2, frame: $0) })
        let heard = Self.joined(chunks)
        #expect(heard.count >= 59 * 1_600)
        let coupling = gate.coupling ?? 0
        #expect(coupling > 0.2 && coupling < 0.3)
        #expect(gate.silencedFrames >= 25)
        // The last two seconds the Me recognizer hears are silence.
        let tail = heard.suffix(20 * 1_600)
        #expect(tail.allSatisfy { $0 == 0 })
    }

    @Test func talkingOverThemStillPasses() {
        var gate = EchoGate()
        _ = Self.run(
            &gate, from: 0, to: 40,
            mic: { Self.tone(440, amplitude: 0.05, frame: $0) },
            system: { Self.tone(440, amplitude: 0.2, frame: $0) })
        let silencedBefore = gate.silencedFrames
        let chunks = Self.run(
            &gate, from: 40, to: 60,
            mic: { frame in
                zip(Self.tone(440, amplitude: 0.05, frame: frame), Self.tone(220, amplitude: 0.3, frame: frame))
                    .map { Int16(clamping: Int($0) + Int($1)) }
            },
            system: { Self.tone(440, amplitude: 0.2, frame: $0) })
        // At most the frame straddling the switch is touched.
        #expect(gate.silencedFrames - silencedBefore <= 1)
        let heard = Self.joined(chunks)
        #expect(heard.suffix(10 * 1_600).contains { $0 != 0 })
    }

    @Test func headphonesLeaveYourVoiceAlone() {
        var gate = EchoGate()
        // They talk; your mic only has faint room noise.
        _ = Self.run(
            &gate, from: 0, to: 40,
            mic: { Self.tone(97, amplitude: 0.002, frame: $0) },
            system: { Self.tone(440, amplitude: 0.2, frame: $0) })
        // You answer while they pause.
        let chunks = Self.run(
            &gate, from: 40, to: 60,
            mic: { Self.tone(220, amplitude: 0.3, frame: $0) },
            system: { _ in Self.silence() })
        let heard = Self.joined(chunks)
        let expected = (40..<59).flatMap { Self.tone(220, amplitude: 0.3, frame: Int64($0) * 1_600) }
        #expect(Array(heard.prefix(expected.count)) == expected)
    }

    @Test func outputIsContiguousAndComplete() {
        var gate = EchoGate()
        var chunks = Self.run(
            &gate, from: 0, to: 50,
            mic: { Self.tone(440, amplitude: 0.05, frame: $0) },
            system: { Self.tone(440, amplitude: 0.2, frame: $0) })
        chunks += gate.flush()
        var next: Int64 = 0
        for chunk in chunks {
            #expect(chunk.startFrame == next)
            next = chunk.startFrame + Int64(chunk.samples.count)
        }
        #expect(next == 50 * 1_600)
    }

    @Test func neverHoldsMicLongWhenTheSystemLaneStalls() {
        var gate = EchoGate()
        _ = gate.addSystem(Self.tone(440, amplitude: 0.2, frame: 0), startFrame: 0)
        var released = 0
        for index in 0..<12 {
            let frame = Int64(index) * 1_600
            released += gate.addMic(Self.tone(220, amplitude: 0.3, frame: frame), startFrame: frame)
                .reduce(0) { $0 + $1.samples.count }
        }
        // 1.2 s of mic in, system stuck after 0.1 s: everything older than
        // the 0.5 s hold has gone out.
        #expect(released >= 12 * 1_600 - Int(EchoGate.maxHold) - 1_600)
        let rest = gate.flush().reduce(0) { $0 + $1.samples.count }
        #expect(released + rest == 12 * 1_600)
    }

    @Test func gapsInTheMicLaneReleaseWhatWasHeld() {
        var gate = EchoGate()
        _ = gate.addSystem(Self.tone(440, amplitude: 0.2, frame: 0), startFrame: 0)
        let first = gate.addMic(Self.tone(220, amplitude: 0.3, frame: 0, count: 800), startFrame: 0)
        #expect(first.isEmpty)
        let afterGap = gate.addMic(Self.tone(220, amplitude: 0.3, frame: 16_000), startFrame: 16_000)
        #expect(afterGap.first?.startFrame == 0)
        #expect(afterGap.first?.samples.count == 800)
    }
}
