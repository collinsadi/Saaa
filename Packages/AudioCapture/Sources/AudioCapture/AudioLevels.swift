import Foundation

/// A momentary level reading for one capture channel, computed by the drain
/// task per cycle — the UI's dual Me/Them meters bind to a stream of these.
public struct AudioLevels: Sendable, Equatable {
    /// Root-mean-square level in linear full scale, 0...1.
    public let rms: Float
    /// Absolute peak in linear full scale, 0...1.
    public let peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    /// Silence.
    public static let zero = AudioLevels(rms: 0, peak: 0)

    /// Computes levels over a buffer of float samples.
    public init(samples: UnsafePointer<Float32>, count: Int) {
        guard count > 0 else {
            self = .zero
            return
        }
        var sumSquares: Float = 0
        var maxAbs: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sumSquares += s * s
            let a = abs(s)
            if a > maxAbs { maxAbs = a }
        }
        self.rms = min(1, (sumSquares / Float(count)).squareRoot())
        self.peak = min(1, maxAbs)
    }

    /// RMS expressed in dBFS, floored at -80 dB for UI mapping.
    public var rmsDecibels: Float {
        guard rms > 0 else { return -80 }
        return max(-80, 20 * log10(rms))
    }
}
