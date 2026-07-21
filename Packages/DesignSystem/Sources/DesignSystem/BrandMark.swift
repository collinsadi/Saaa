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
        // Tight bounds: the mark's content is 60×64 in source units, drawn
        // edge to edge so it aligns optically with neighboring text (no
        // phantom padding). `size` is the mark's HEIGHT.
        let unit = size / 64
        let inkColor = ink ?? saaa.textPrimary
        ZStack(alignment: .topLeading) {
            // Sizing layer: ZStack measures child FRAMES and ignores
            // offsets, so without this the stack collapses to 60x16 and the
            // offset bars render outside the declared bounds (the alignment
            // bug seen next to text).
            Color.clear
                .frame(width: 60 * unit, height: 64 * unit)
            RoundedRectangle(cornerRadius: 8 * unit)
                .fill(inkColor)
                .frame(width: 44 * unit, height: 16 * unit)
                .offset(x: 16 * unit, y: 0)
            RoundedRectangle(cornerRadius: 8 * unit)
                .fill(inkColor)
                .frame(width: 60 * unit, height: 16 * unit)
                .offset(x: 0, y: 24 * unit)
            RoundedRectangle(cornerRadius: 8 * unit)
                .fill(inkColor)
                .frame(width: 40 * unit, height: 16 * unit)
                .offset(x: 0, y: 48 * unit)
            Circle()
                .fill(ember ?? saaa.emberLamp)
                .frame(width: 16 * unit, height: 16 * unit)
                .offset(x: 44 * unit, y: 48 * unit)
        }
        .frame(width: 60 * unit, height: size)
        .accessibilityHidden(true)
    }
}
