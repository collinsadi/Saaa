import DesignSystem
import SwiftUI

/// Shared hub-pane scaffolding (UI-PLAN §4.6). Every pane adopts the same
/// header, measure, empty-state voice, and status chips so nothing hand-rolls
/// its own drift.
///
/// Copy voice: sentence case, no exclamation marks, no em dashes; queues say
/// "…it lands here"; errors are never empty states; raw error strings never
/// render as body text (they live in `.help()` tooltips). UI text stays
/// brief — extended explanations go behind a `HelpDot`.

/// Caps pane content at the shared measure, leading-aligned: empty space
/// accrues on the right as instrument margin, never as a lost centered strip.
struct PaneColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: Size.contentColumnMax, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The pane header row: title2 title + trailing toolbar slot, then an
/// optional one-line subtitle with an optional HelpDot for the long version.
struct PaneHeader<Toolbar: View>: View {
    let title: String
    var subtitle: String?
    var help: String?
    @ViewBuilder var toolbar: Toolbar

    @Environment(\.saaa) private var saaa

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title)
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
                toolbar
            }
            if let subtitle {
                HStack(spacing: Space.sm) {
                    Text(subtitle)
                        .font(SaaaFont.callout)
                        .foregroundStyle(saaa.textSecondary)
                    if let help {
                        HelpDot(help)
                    }
                }
            }
        }
    }
}

extension PaneHeader where Toolbar == EmptyView {
    init(title: String, subtitle: String? = nil, help: String? = nil) {
        self.init(title: title, subtitle: subtitle, help: help) { EmptyView() }
    }
}

/// One empty-state voice: headline, one active guidance sentence, optional
/// hotkey chip. Left-aligned, no card, no icon, no motion.
struct PaneEmptyState: View {
    let headline: String
    let guidance: String
    var hotkey: String?

    @Environment(\.saaa) private var saaa

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(headline)
                .font(SaaaFont.headline)
                .foregroundStyle(saaa.textPrimary)
            HStack(spacing: Space.sm) {
                Text(guidance)
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
                if let hotkey {
                    Text(hotkey)
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.textSecondary)
                        .padding(.horizontal, Space.sm)
                        .frame(height: Size.controlSm)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm).fill(saaa.surfaceInset))
                }
            }
        }
        .padding(.vertical, Space.lg)
    }
}

/// Engraved status chip on an inset capsule — replaces the hand-rolled chip
/// renderers in the import and queue lists.
struct StatusChip: View {
    let text: String
    let color: Color

    @Environment(\.saaa) private var saaa

    var body: some View {
        Text(text)
            .engravedLabelStyle()
            .foregroundStyle(color)
            .padding(.horizontal, Space.sm)
            .frame(height: 18)
            .background(Capsule().fill(saaa.surfaceInset))
    }
}
