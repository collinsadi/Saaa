import SwiftUI

/// One lane of the dual Me/Them meter — a row of thin bars, lit from the
/// left by the current level. The ONE kinetic element while recording.
/// Frozen at the last level under Reduce Motion.
public struct LevelBars: View {
    @Environment(\.saaa) private var saaa
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Linear RMS 0...1.
    private let level: Float
    private let barCount: Int

    @State private var frozenLevel: Float = 0

    public init(level: Float, barCount: Int = 20) {
        self.level = level
        self.barCount = barCount
    }

    public var body: some View {
        let displayed = reduceMotion ? frozenLevel : level
        // Perceptual mapping: RMS → lit fraction with a gentle log-ish curve.
        let lit = Int((min(1, displayed * 3.2)).squareRoot() * Float(barCount))
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? saaa.emberLamp : saaa.borderHairline)
                    .frame(width: 2)
                    .frame(height: barHeight(index: index, lit: index < lit))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .onAppear { frozenLevel = level }
        .accessibilityHidden(true)
    }

    /// Lit bars vary height slightly for the instrument look; unlit stay low.
    private func barHeight(index: Int, lit: Bool) -> CGFloat {
        guard lit else { return 5 }
        let variation: [CGFloat] = [9, 12, 10, 13, 11, 12, 9, 11]
        return variation[index % variation.count]
    }
}
