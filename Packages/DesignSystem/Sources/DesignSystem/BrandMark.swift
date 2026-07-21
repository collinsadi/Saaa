import SwiftUI

/// The Saaa mark (locked 2026-07-21): three staggered level-meter bars
/// tracing an S, the ember lamp dot completing the bottom row. Drawn
/// natively so it stays crisp at any size and follows the active palette.
public struct BrandMark: View {
    @Environment(\.saaa) private var saaa

    private let size: CGFloat
    private let ink: Color?
    private let ember: Color?

    /// `ink`/`ember` default to the palette's text-primary and ember lamp.
    public init(size: CGFloat = 24, ink: Color? = nil, ember: Color? = nil) {
        self.size = size
        self.ink = ink
        self.ember = ember
    }

    public var body: some View {
        let unit = size / 96
        let inkColor = ink ?? saaa.textPrimary
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8 * unit)
                .fill(inkColor)
                .frame(width: 44 * unit, height: 16 * unit)
                .offset(x: 34 * unit, y: 16 * unit)
            RoundedRectangle(cornerRadius: 8 * unit)
                .fill(inkColor)
                .frame(width: 60 * unit, height: 16 * unit)
                .offset(x: 18 * unit, y: 40 * unit)
            RoundedRectangle(cornerRadius: 8 * unit)
                .fill(inkColor)
                .frame(width: 40 * unit, height: 16 * unit)
                .offset(x: 18 * unit, y: 64 * unit)
            Circle()
                .fill(ember ?? saaa.emberLamp)
                .frame(width: 16 * unit, height: 16 * unit)
                .offset(x: 62 * unit, y: 64 * unit)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
