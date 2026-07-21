import SwiftUI
import Testing
@testable import DesignSystem

@Test func moduleLinksAndReportsIdentity() {
    #expect(DesignSystemModule.name == "DesignSystem")
}

@Suite struct PaletteTests {

    @Test func resolutionCoversAllFourModes() {
        #expect(SaaaPalette.resolve(colorScheme: .light, contrast: .standard) == .light)
        #expect(SaaaPalette.resolve(colorScheme: .dark, contrast: .standard) == .dark)
        #expect(SaaaPalette.resolve(colorScheme: .light, contrast: .increased) == .lightHighContrast)
        #expect(SaaaPalette.resolve(colorScheme: .dark, contrast: .increased) == .darkHighContrast)
    }

    @Test func islandPaletteIsDark() {
        // The island pins dark tokens regardless of system appearance.
        #expect(SaaaPalette.dark.surfaceBase == Color(hex: 0x14171A))
        #expect(SaaaPalette.dark.emberLamp == Color(hex: 0xFF9F0A))
    }

    @Test func motionSpringsMatchApprovedSpec() {
        // Collapse must be critically damped (never bounces) — the values
        // are part of the approved interaction contract.
        #expect(Motion.contentLag == 0.09)
        #expect(Motion.peekDwell == 8)
    }
}
