import SwiftUI

/// Confidence per the state grammar: numeral + worded tier + segmented
/// meter — never a bare traffic light. Shared by Review's match card and
/// History's filed-to card (the island peek's numeral-only line is the one
/// blessed compact exception).
public struct ConfidenceRow: View {
    let confidence: Double

    @Environment(\.saaa) private var saaa

    public init(confidence: Double) {
        self.confidence = confidence
    }

    public var body: some View {
        let tier = confidence >= 0.75 ? "high" : confidence >= 0.45 ? "medium" : "low"
        let color = confidence >= 0.75
            ? saaa.confidenceHigh : confidence >= 0.45
            ? saaa.confidenceMedium : saaa.confidenceLow
        return HStack(spacing: Space.sm) {
            Text(String(format: "%.2f", confidence))
                .font(SaaaFont.readoutValue)
                .foregroundStyle(saaa.textPrimary)
            Text(tier).engravedLabelStyle().foregroundStyle(color)
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(index) < confidence * 6 ? color : saaa.surfaceInset)
                        .frame(width: 14, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidence \(Int(confidence * 100)) percent, \(tier)")
    }
}

/// The help affordance (user copy rule): UI text stays brief, and the long
/// explanation lives behind this "?" dot — tooltip on hover, popover on
/// click. UI strings never contain em dashes.
public struct HelpDot: View {
    let tip: String

    @Environment(\.saaa) private var saaa
    @State private var shown = false

    public init(_ tip: String) {
        self.tip = tip
    }

    public var body: some View {
        Button {
            shown.toggle()
        } label: {
            Text("?")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(saaa.textTertiary)
                .frame(width: 14, height: 14)
                .background(Circle().fill(saaa.surfaceInset))
                .overlay(Circle().strokeBorder(saaa.borderHairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tip)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(tip)
                .font(SaaaFont.callout)
                .foregroundStyle(saaa.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.md)
                .frame(width: 260, alignment: .leading)
        }
        .accessibilityLabel("More info")
    }
}
