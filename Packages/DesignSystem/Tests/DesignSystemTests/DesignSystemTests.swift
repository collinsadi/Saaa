import Core
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

    @Test func islandStaysTrueBlack() {
        #expect(SaaaPalette.islandSurface == Color(hex: 0x000000))
        #expect(SaaaPalette.dark.emberLamp == Color(hex: 0xFF9F0A))
    }

    @Test func everyPlaybookTintHasADistinctColor() {
        let colors = PlaybookTint.allCases.map(\.color)
        #expect(Set(colors.map { "\($0)" }).count == PlaybookTint.allCases.count)
    }

    @Test func motionContractsHold() {
        #expect(Motion.contentLag == 0.09)
        #expect(Motion.peekDwell == 8)
        #expect(Radius.panel > Radius.card && Radius.card > Radius.control)
    }
}
