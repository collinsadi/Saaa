import Core
import SwiftUI

/// A quick-action chip: glass capsule, SF Symbol, title, optional key hint.
public struct ActionChip: View {
    let title: String
    let symbol: String?
    let hint: String?
    let prominent: Bool
    let isBusy: Bool
    let action: () -> Void

    @Environment(\.saaa) private var saaa

    public init(
        _ title: String, symbol: String? = nil, hint: String? = nil,
        prominent: Bool = false, isBusy: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.hint = hint
        self.prominent = prominent
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .saaaGlass(in: Capsule(), tint: prominent ? saaa.tideFill : nil, interactive: true)
        .accessibilityLabel(title)
    }
}

/// A keyboard shortcut hint ("⌥⌘A").
public struct KeyCap: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            .accessibilityLabel("Shortcut \(text)")
    }
}

/// Engraved section label: SF Mono caps, the instrument voice.
public struct SectionLabel: View {
    let text: String
    let trailing: String?

    public init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: Space.sm) {
            Text(text).engravedLabelStyle()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A playbook's symbol and name in its tint.
public struct PlaybookBadge: View {
    let playbook: Playbook
    let compact: Bool

    public init(_ playbook: Playbook, compact: Bool = false) {
        self.playbook = playbook
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: playbook.symbol)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(playbook.tint.color)
            Text(playbook.name)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text that grows while Claude streams, with a soft caret at the end.
public struct StreamingText: View {
    let text: String
    let isStreaming: Bool
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var caretOn = true

    public init(_ text: String, isStreaming: Bool, font: Font = .system(size: 14)) {
        self.text = text
        self.isStreaming = isStreaming
        self.font = font
    }

    public var body: some View {
        Text(verbatim: text + (isStreaming ? (caretOn ? " ▍" : "  ") : ""))
            .font(font)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: isStreaming) {
                guard isStreaming, !reduceMotion else {
                    caretOn = true
                    return
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(480))
                    caretOn.toggle()
                }
            }
    }
}

/// Me vs Them speaking time.
public struct TalkRatioBar: View {
    let me: Double
    let them: Double

    @Environment(\.saaa) private var saaa

    public init(me: Double, them: Double) {
        self.me = me
        self.them = them
    }

    private var share: Double {
        let total = me + them
        return total > 0 ? me / total : 0.5
    }

    public var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Capsule().fill(saaa.tideEmphasis)
                        .frame(width: max(3, proxy.size.width * share - 1))
                    Capsule().fill(.white.opacity(0.28))
                }
            }
            .frame(width: 44, height: 4)
            Text("\(Int((share * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You've spoken \(Int((share * 100).rounded())) percent of the time")
        .help("Your share of speaking time")
    }
}

/// Empty state: symbol, headline, one sentence, optional action.
public struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(symbol: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity)
    }
}

/// The help affordance: brief UI text, the long explanation behind "?".
public struct HelpDot: View {
    let tip: String

    @State private var shown = false

    public init(_ tip: String) {
        self.tip = tip
    }

    public var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(tip)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(tip)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.md)
                .frame(width: 280, alignment: .leading)
        }
        .accessibilityLabel("More info")
    }
}
