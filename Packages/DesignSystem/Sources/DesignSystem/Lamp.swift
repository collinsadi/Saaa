import SwiftUI

/// The state dot — one lamp, triple-coded (color + REC text + shape).
/// 10 pt glyph in a 12 pt slot. NEVER pulses in any mode (static fill; the
/// level meter is the one kinetic element). Under Differentiate Without
/// Color the recording variant swaps to a square fill automatically.
public struct Lamp: View {
    public enum Variant: Sendable, Equatable {
        /// Outline, border/control.
        case idle
        /// Outline 2 pt, ember.
        case armed
        /// Filled, ember (square under DWC).
        case recording
        /// Processing: waveform glyph, tide emphasis.
        case processing
        /// Error: filled, danger.
        case error
    }

    @Environment(\.saaa) private var saaa
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    private let variant: Variant

    public init(_ variant: Variant) {
        self.variant = variant
    }

    public var body: some View {
        Group {
            switch variant {
            case .idle:
                Circle().strokeBorder(saaa.borderControl, lineWidth: 1)
            case .armed:
                Circle().strokeBorder(saaa.emberLamp, lineWidth: 2)
            case .recording:
                if differentiate {
                    Rectangle().fill(saaa.emberLamp)
                } else {
                    Circle().fill(saaa.emberLamp)
                }
            case .processing:
                Image(systemName: "waveform")
                    .font(.system(size: Size.lampGlyph, weight: .semibold))
                    .foregroundStyle(saaa.tideEmphasis)
            case .error:
                if differentiate {
                    Rectangle().fill(saaa.dangerFill)
                } else {
                    Circle().fill(saaa.dangerFill)
                }
            }
        }
        .frame(width: Size.lampGlyph, height: Size.lampGlyph)
        .frame(width: Size.lampSlot, height: Size.lampSlot)
        .animation(Motion.fast, value: variant)
        .accessibilityHidden(true) // always paired with a state word
    }
}
