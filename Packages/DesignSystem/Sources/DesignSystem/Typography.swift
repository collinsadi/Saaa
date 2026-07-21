import SwiftUI

/// The Field Instrument type ramp. Figma previews use Inter + Roboto Mono;
/// the runtime binding (recorded in each style's description) is SF Pro +
/// SF Mono — prose is SF Pro, readouts/timecode/engraved labels are SF Mono.
public enum SaaaFont {
    // Prose (SF Pro).
    public static let title1 = Font.system(size: 22, weight: .bold)
    public static let title2 = Font.system(size: 17, weight: .semibold)
    public static let headline = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let callout = Font.system(size: 12, weight: .regular)
    public static let caption = Font.system(size: 10, weight: .medium)

    // Data rail (SF Mono).
    public static let monoBody = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let monoCaption = Font.system(size: 10, weight: .regular, design: .monospaced)
    public static let readoutValue = Font.system(size: 13, weight: .regular, design: .monospaced)
    public static let readoutTimer = Font.system(size: 21, weight: .medium, design: .monospaced)
    public static let engraved = Font.system(size: 10, weight: .medium, design: .monospaced)
}

extension View {
    /// label/engraved: SF Mono 10 medium, tracked caps — the hardware-label
    /// voice ("REC", "ME", "THEM").
    public func engravedLabelStyle() -> some View {
        font(SaaaFont.engraved)
            .tracking(1.4)
            .textCase(.uppercase)
    }
}
