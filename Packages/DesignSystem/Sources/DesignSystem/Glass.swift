import Core
import SwiftUI

/// Liquid Glass, the Saaa way: one modifier for every floating surface so
/// Reduce Transparency, tint and shape stay consistent. Under Reduce
/// Transparency glass becomes a solid raised surface with a hairline.
public struct SaaaGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.saaa) private var saaa

    public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(saaa.surfaceOverlay))
                .overlay(shape.strokeBorder(saaa.borderHairline, lineWidth: 1))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive(true) }
        return glass
    }
}

extension View {
    /// Floats this view on Liquid Glass in `shape`.
    public func saaaGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(SaaaGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// Glass in a rounded rectangle (concentric radii).
    public func saaaGlass(cornerRadius: CGFloat = Radius.card, tint: Color? = nil, interactive: Bool = false) -> some View {
        saaaGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive)
    }

    /// A solid reading card: content that must stay legible never sits on glass.
    public func saaaCard(cornerRadius: CGFloat = Radius.card, padding: CGFloat = Space.lg) -> some View {
        modifier(CardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

private struct CardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    @Environment(\.saaa) private var saaa

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(saaa.surfaceRaised))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(saaa.borderHairline.opacity(0.7), lineWidth: 1))
    }
}

// MARK: - Playbook tints

extension PlaybookTint {
    /// The accent for a playbook family (saturated enough to read on glass).
    public var color: Color {
        switch self {
        case .tide: Color(hex: 0x3A8FB7)
        case .ember: Color(hex: 0xE8890C)
        case .violet: Color(hex: 0x8B6CEF)
        case .green: Color(hex: 0x2FA36B)
        case .rose: Color(hex: 0xE0577A)
        case .amber: Color(hex: 0xD4A017)
        case .slate: Color(hex: 0x7B8794)
        case .sky: Color(hex: 0x3BA7E0)
        }
    }
}
