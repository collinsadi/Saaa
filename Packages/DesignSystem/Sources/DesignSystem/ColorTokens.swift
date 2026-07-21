import SwiftUI

/// The Field Instrument semantic palette — generated from the Figma
/// Foundations (file WiUixg1DLmEgVZL3SYz2RN, collection "Semantic", 4 modes),
/// WCAG AA verified per pair (7:1 in the HC modes). Never use a raw hex in a
/// component — bind these tokens.
public struct SaaaPalette: Sendable, Equatable {
    // Surfaces (opaque — the system has zero translucency by rule).
    public let surfaceBase: Color
    public let surfaceRaised: Color
    public let surfaceInset: Color
    public let surfaceOverlay: Color
    // Text.
    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let textOnAccent: Color
    // Borders.
    public let borderHairline: Color
    public let borderControl: Color
    // Ember — the REC lamp family (recording only, never decorative).
    public let emberLamp: Color
    public let emberText: Color
    // Tide — passive interactive.
    public let tideFill: Color
    public let tideText: Color
    public let tideEmphasis: Color
    // Status.
    public let successText: Color
    public let dangerFill: Color
    public let dangerText: Color
    // Confidence tiers (numeral + worded tier + meter; never traffic-light).
    public let confidenceHigh: Color
    public let confidenceMedium: Color
    public let confidenceLow: Color

    /// Light mode.
    public static let light = SaaaPalette(
        surfaceBase: Color(hex: 0xECEEEF), surfaceRaised: Color(hex: 0xF7F8F9),
        surfaceInset: Color(hex: 0xE2E5E7), surfaceOverlay: Color(hex: 0xFFFFFF),
        textPrimary: Color(hex: 0x16191C), textSecondary: Color(hex: 0x454C52),
        textTertiary: Color(hex: 0x5C636A), textOnAccent: Color(hex: 0xFFFFFF),
        borderHairline: Color(hex: 0xC6CACD), borderControl: Color(hex: 0x84898F),
        emberLamp: Color(hex: 0xBF5A00), emberText: Color(hex: 0x9C4A00),
        tideFill: Color(hex: 0x2C6E8A), tideText: Color(hex: 0x1F5B74),
        tideEmphasis: Color(hex: 0x2C6E8A),
        successText: Color(hex: 0x1F6B47),
        dangerFill: Color(hex: 0xAD2E24), dangerText: Color(hex: 0xAD2E24),
        confidenceHigh: Color(hex: 0x2C6E8A), confidenceMedium: Color(hex: 0x5C636A),
        confidenceLow: Color(hex: 0xBF5A00))

    /// Dark mode — also the island's permanent palette (always-dark rule).
    public static let dark = SaaaPalette(
        surfaceBase: Color(hex: 0x14171A), surfaceRaised: Color(hex: 0x1D2024),
        surfaceInset: Color(hex: 0x0F1114), surfaceOverlay: Color(hex: 0x24282C),
        textPrimary: Color(hex: 0xE9EBED), textSecondary: Color(hex: 0xB6BCC2),
        textTertiary: Color(hex: 0x99A0A7), textOnAccent: Color(hex: 0xFFFFFF),
        borderHairline: Color(hex: 0x2B2F34), borderControl: Color(hex: 0x6E757C),
        emberLamp: Color(hex: 0xFF9F0A), emberText: Color(hex: 0xFFA82E),
        tideFill: Color(hex: 0x2E7D9C), tideText: Color(hex: 0x96CFE5),
        tideEmphasis: Color(hex: 0x7CC1DB),
        successText: Color(hex: 0x7FC9A4),
        dangerFill: Color(hex: 0xAD2E24), dangerText: Color(hex: 0xFF8A80),
        confidenceHigh: Color(hex: 0x7CC1DB), confidenceMedium: Color(hex: 0x99A0A7),
        confidenceLow: Color(hex: 0xFF9F0A))

    /// Light, increased contrast (7:1).
    public static let lightHighContrast = SaaaPalette(
        surfaceBase: Color(hex: 0xECEEEF), surfaceRaised: Color(hex: 0xF7F8F9),
        surfaceInset: Color(hex: 0xE2E5E7), surfaceOverlay: Color(hex: 0xFFFFFF),
        textPrimary: Color(hex: 0x0B0D0F), textSecondary: Color(hex: 0x33393F),
        textTertiary: Color(hex: 0x3E444B), textOnAccent: Color(hex: 0xFFFFFF),
        borderHairline: Color(hex: 0x6B7278), borderControl: Color(hex: 0x545B61),
        emberLamp: Color(hex: 0x9C4A00), emberText: Color(hex: 0x7E3B00),
        tideFill: Color(hex: 0x17465C), tideText: Color(hex: 0x17465C),
        tideEmphasis: Color(hex: 0x17465C),
        successText: Color(hex: 0x175237),
        dangerFill: Color(hex: 0x8F241C), dangerText: Color(hex: 0x8F241C),
        confidenceHigh: Color(hex: 0x17465C), confidenceMedium: Color(hex: 0x3E444B),
        confidenceLow: Color(hex: 0x7E3B00))

    /// Dark, increased contrast (7:1).
    public static let darkHighContrast = SaaaPalette(
        surfaceBase: Color(hex: 0x14171A), surfaceRaised: Color(hex: 0x1D2024),
        surfaceInset: Color(hex: 0x0F1114), surfaceOverlay: Color(hex: 0x24282C),
        textPrimary: Color(hex: 0xF5F7F8), textSecondary: Color(hex: 0xD2D7DB),
        textTertiary: Color(hex: 0xB6BCC2), textOnAccent: Color(hex: 0x0B0D0F),
        borderHairline: Color(hex: 0x656C73), borderControl: Color(hex: 0x8A9096),
        emberLamp: Color(hex: 0xFFB13D), emberText: Color(hex: 0xFFB13D),
        tideFill: Color(hex: 0x7CC1DB), tideText: Color(hex: 0xABDBF0),
        tideEmphasis: Color(hex: 0xABDBF0),
        successText: Color(hex: 0x9AD8BB),
        dangerFill: Color(hex: 0xFFA39B), dangerText: Color(hex: 0xFFA39B),
        confidenceHigh: Color(hex: 0xABDBF0), confidenceMedium: Color(hex: 0xB6BCC2),
        confidenceLow: Color(hex: 0xFFB13D))

    /// Resolves the palette for the current environment.
    public static func resolve(
        colorScheme: ColorScheme, contrast: ColorSchemeContrast
    ) -> SaaaPalette {
        switch (colorScheme, contrast) {
        case (.dark, .increased): .darkHighContrast
        case (.dark, _): .dark
        case (_, .increased): .lightHighContrast
        default: .light
        }
    }
}

extension SaaaPalette {
    /// The island's surface: TRUE black, matching the hardware notch cutout
    /// exactly so tiers read as the notch itself morphing (user direction
    /// 2026-07-21 — deliberately deeper than surface/base #14171A, island
    /// only; window surfaces keep the Field Instrument grays).
    public static let islandSurface = Color(hex: 0x000000)
}

extension Color {
    /// Token constructor — internal to the design system; components never
    /// call this directly.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Environment plumbing

private struct SaaaPaletteKey: EnvironmentKey {
    static let defaultValue = SaaaPalette.light
}

extension EnvironmentValues {
    /// The active Field Instrument palette. Windows follow the system
    /// appearance via ``View/saaaThemed()``; the island pins `.dark`.
    public var saaa: SaaaPalette {
        get { self[SaaaPaletteKey.self] }
        set { self[SaaaPaletteKey.self] = newValue }
    }
}

extension View {
    /// Resolves the palette from the system appearance (light/dark ×
    /// contrast) and injects it as `\.saaa`.
    public func saaaThemed() -> some View {
        modifier(SaaaThemeModifier())
    }

    /// Pins the palette regardless of system appearance (the island is
    /// always dark — it fuses with the hardware notch).
    public func saaaThemed(fixed palette: SaaaPalette) -> some View {
        environment(\.saaa, palette)
    }
}

private struct SaaaThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.environment(
            \.saaa, SaaaPalette.resolve(colorScheme: colorScheme, contrast: contrast))
    }
}
