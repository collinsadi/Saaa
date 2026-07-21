import Foundation
import Testing
@testable import AudioCapture

@Suite struct AudioLevelsTests {

    @Test func silenceIsZero() {
        let samples = [Float32](repeating: 0, count: 256)
        let levels = samples.withUnsafeBufferPointer {
            AudioLevels(samples: $0.baseAddress!, count: $0.count)
        }
        #expect(levels == .zero)
        #expect(levels.rmsDecibels == -80)
    }

    @Test func fullScaleSquareWaveIsUnity() {
        let samples = [Float32](repeating: 1, count: 256)
        let levels = samples.withUnsafeBufferPointer {
            AudioLevels(samples: $0.baseAddress!, count: $0.count)
        }
        #expect(abs(levels.rms - 1) < 0.0001)
        #expect(levels.peak == 1)
        #expect(abs(levels.rmsDecibels) < 0.01)
    }

    @Test func sineWaveRMSIsMinusThreeDecibels() {
        var samples = [Float32](repeating: 0, count: 16_000)
        for i in samples.indices {
            samples[i] = sinf(2 * .pi * 440 * Float(i) / 16_000)
        }
        let levels = samples.withUnsafeBufferPointer {
            AudioLevels(samples: $0.baseAddress!, count: $0.count)
        }
        // Sine RMS = 1/sqrt(2) ≈ -3.01 dBFS.
        #expect(abs(levels.rms - 0.7071) < 0.001)
        #expect(abs(levels.rmsDecibels - (-3.01)) < 0.05)
        #expect(levels.peak > 0.999)
    }

    @Test func emptyBufferIsZero() {
        let samples: [Float32] = [1]
        let levels = samples.withUnsafeBufferPointer {
            AudioLevels(samples: $0.baseAddress!, count: 0)
        }
        #expect(levels == .zero)
    }
}
