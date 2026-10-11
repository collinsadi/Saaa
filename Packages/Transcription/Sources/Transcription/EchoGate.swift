import Foundation

/// Keeps speaker echo out of the Me lane.
///
/// On laptop speakers the mic hears the other side, and the recognizer turns
/// that echo into garbled "Me" lines that text matching can't catch. Both
/// lanes share one 16 kHz timeline, so the gate compares their energy in
/// 100 ms frames: while the other side is talking, a mic frame that carries
/// no more energy than the learned speaker-to-mic coupling predicts is echo,
/// and the Me recognizer hears silence instead. Talking over them passes,
/// and on headphones the coupling is tiny, so nothing real is touched. The
/// recorded audio is never altered.
struct EchoGate: Sendable {

    struct Chunk: Sendable, Equatable {
        var samples: [Int16]
        var startFrame: Int64
    }

    /// 100 ms at 16 kHz.
    static let frameLength: Int64 = 1_600
    /// The other side counts as talking above this RMS (about -40 dBFS).
    static let activeLevel: Float = 0.01
    /// A mic frame must beat the predicted echo by this factor (6 dB) to pass.
    static let margin: Float = 2
    /// Frames of their speech observed before the coupling is trusted (3 s).
    static let warmupFrames = 30
    /// Ratios remembered for the coupling estimate (30 s of their speech).
    static let window = 300
    /// Mic audio is never held more than this waiting for the system lane.
    static let maxHold: Int64 = 8_000

    // System lane: RMS per completed frame.
    private var systemLevels: [Int64: Float] = [:]
    private var systemFrame: Int64 = -1
    private var systemSquares: Double = 0
    private var systemCount = 0
    private var systemEnd: Int64 = 0
    private var systemStarted = false

    // Mic samples not yet released to the recognizer.
    private var pending: [Int16] = []
    private var pendingStart: Int64 = 0

    // Mic-to-system energy ratios while they talk.
    private var ratios: [Float] = []
    private var ratioIndex = 0

    /// The learned speaker-to-mic coupling; nil until warmed up.
    private(set) var coupling: Float?
    /// Mic frames replaced with silence so far.
    private(set) var silencedFrames = 0

    var silencedSeconds: Double {
        Double(silencedFrames) * Double(Self.frameLength) / 16_000
    }

    // MARK: - Input

    /// The other side's audio. Returns mic audio that is now decided.
    mutating func addSystem(_ samples: [Int16], startFrame: Int64) -> [Chunk] {
        guard !samples.isEmpty else { return [] }
        systemStarted = true
        var position = startFrame
        for sample in samples {
            let frame = position / Self.frameLength
            if frame != systemFrame {
                closeSystemFrame()
                systemFrame = frame
            }
            let value = Double(sample) / 32_768
            systemSquares += value * value
            systemCount += 1
            position += 1
        }
        if position % Self.frameLength == 0 {
            closeSystemFrame()
        }
        systemEnd = max(systemEnd, position)
        return release(final: false)
    }

    /// Your mic audio. Returns mic audio that is now decided, in order.
    mutating func addMic(_ samples: [Int16], startFrame: Int64) -> [Chunk] {
        guard !samples.isEmpty else { return [] }
        var released: [Chunk] = []
        if !pending.isEmpty, startFrame != pendingStart + Int64(pending.count) {
            released += release(final: true)
        }
        if pending.isEmpty {
            pendingStart = startFrame
        }
        pending += samples
        released += release(final: false)
        return released
    }

    /// End of input: decides and returns everything still held.
    mutating func flush() -> [Chunk] {
        closeSystemFrame()
        return release(final: true)
    }

    // MARK: - Decisions

    private mutating func release(final: Bool) -> [Chunk] {
        guard !pending.isEmpty else { return [] }
        let pendingEnd = pendingStart + Int64(pending.count)
        var output = pending
        var cut = pendingStart
        while cut < pendingEnd {
            let frame = cut / Self.frameLength
            let frameEnd = (frame + 1) * Self.frameLength
            let micComplete = pendingEnd >= frameEnd
            guard micComplete || final else { break }
            let systemKnown = !systemStarted
                || systemEnd >= frameEnd
                || pendingEnd - frameEnd >= Self.maxHold
            guard systemKnown || final else { break }
            let lower = Int(cut - pendingStart)
            let upper = Int(min(pendingEnd, frameEnd) - pendingStart)
            if shouldSilence(frame: frame, samples: output[lower..<upper]) {
                for index in lower..<upper {
                    output[index] = 0
                }
                silencedFrames += 1
            }
            cut = pendingStart + Int64(upper)
        }
        guard cut > pendingStart else { return [] }
        let count = Int(cut - pendingStart)
        let chunk = Chunk(samples: Array(output[0..<count]), startFrame: pendingStart)
        pending.removeFirst(count)
        pendingStart = cut
        pruneSystemLevels(before: pendingStart / Self.frameLength - 2)
        return [chunk]
    }

    private mutating func shouldSilence(frame: Int64, samples: ArraySlice<Int16>) -> Bool {
        guard !samples.isEmpty else { return false }
        // Echo trails the tap by the output and input latency: look one frame back too.
        let system = max(systemLevels[frame] ?? 0, systemLevels[frame - 1] ?? 0)
        guard system >= Self.activeLevel else { return false }
        let mic = Self.rms(samples)
        let estimate = coupling
        learn(mic / system)
        guard let estimate else { return false }
        return mic <= estimate * system * Self.margin
    }

    /// A low percentile of recent ratios: echo-only frames dominate the low
    /// end even when you talk over them now and then.
    private mutating func learn(_ ratio: Float) {
        if ratios.count < Self.window {
            ratios.append(ratio)
        } else {
            ratios[ratioIndex] = ratio
            ratioIndex = (ratioIndex + 1) % Self.window
        }
        guard ratios.count >= Self.warmupFrames else { return }
        let sorted = ratios.sorted()
        coupling = sorted[Int(Float(sorted.count - 1) * 0.3)]
    }

    private mutating func closeSystemFrame() {
        if systemFrame >= 0, systemCount > 0 {
            systemLevels[systemFrame] = Float((systemSquares / Double(systemCount)).squareRoot())
        }
        systemFrame = -1
        systemSquares = 0
        systemCount = 0
    }

    private mutating func pruneSystemLevels(before frame: Int64) {
        guard systemLevels.count > 64 else { return }
        systemLevels = systemLevels.filter { $0.key >= frame }
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            let value = Double(sample) / 32_768
            sum += value * value
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}
