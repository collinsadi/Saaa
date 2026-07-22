import SwiftUI

/// Spacing scale (Figma "Numbers" collection, space/*).
public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32
    public static let huge: CGFloat = 44
}

/// Corner radii (radius/*).
public enum Radius {
    public static let sm: CGFloat = 4
    public static let md: CGFloat = 6
    public static let lg: CGFloat = 8
    public static let xl: CGFloat = 16
    public static let full: CGFloat = 999
}

/// Control and component sizes (size/*).
public enum Size {
    public static let controlSm: CGFloat = 20
    public static let controlMd: CGFloat = 24
    public static let controlLg: CGFloat = 28
    public static let panelWidth: CGFloat = 336
    /// Hub navigation rail width.
    public static let sidebarWidth: CGFloat = 190
    /// PaneColumn measure: pane content caps here, leading-aligned — empty
    /// space accrues on the right as instrument margin.
    public static let contentColumnMax: CGFloat = 640
    /// Transcript surfaces (Review transcript, History detail) read wider.
    public static let transcriptColumnMax: CGFloat = 720
    /// The lamp glyph slot: 10 pt glyph in a 12 pt slot.
    public static let lampSlot: CGFloat = 12
    public static let lampGlyph: CGFloat = 10

    /// Island metrics (size/island-*, verified against the hi-fi frames;
    /// corner radii deepened per user direction 2026-07-21).
    public enum Island {
        /// Compact bar height — extends a hairline's breadth below the notch.
        public static let barHeight: CGFloat = 38
        /// Width of one content flank beside the notch (compact tiers).
        public static let flankWidth: CGFloat = 120
        /// Expanded panel width (H7).
        public static let expandedWidth: CGFloat = 400
        /// The Live Assist tier's width — the copilot thread needs the room;
        /// still inside the fixed 620-wide panel.
        public static let assistWidth: CGFloat = 600
        /// Meter bar strip height inside the flanks.
        public static let meterHeight: CGFloat = 8
        /// Compact bar bottom corners.
        public static let compactRadius: CGFloat = 14
        /// Expanded panel bottom corners.
        public static let expandedRadius: CGFloat = 22
    }
}

/// Motion tokens (motion/*) — from the approved motion spec frame.
/// One kinetic element rule: only the level meter moves while recording.
public enum Motion {
    /// Expand (pill → panel): shape leads, content follows `contentLag`
    /// later. Retuned 2026-07-21 (user direction): slower and silkier than
    /// the original 0.42 — fluid, never abrupt.
    public static let springExpand = Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// Collapse (panel → pill): critically damped — exits NEVER bounce.
    public static let springCollapse = Animation.spring(response: 0.52, dampingFraction: 1.0)
    /// Standard state swap (compact crossfades), 200 ms.
    public static let standard = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
    /// Fast micro-interactions (hover bloom, afterglow), 120 ms.
    public static let fast = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.12)
    /// Content fade-in delay behind an expanding shape.
    public static let contentLag: TimeInterval = 0.09
    /// Peek dwell before auto-retract (suspends while hovered).
    public static let peekDwell: TimeInterval = 8

    /// Reduce Motion variants: opacity crossfade, no scale, no spring.
    public static func expand(reduceMotion: Bool) -> Animation {
        reduceMotion ? standard : springExpand
    }

    public static func collapse(reduceMotion: Bool) -> Animation {
        reduceMotion ? standard : springCollapse
    }
}

/// Elevation effects (fx/*). Never used at menu-bar height — any alpha there
/// swallows menu-bar clicks (verified NSPanel contract).
public enum Elevation {
    /// fx/raised: cards and raised controls.
    public static func raised<Content: View>(_ content: Content) -> some View {
        content.shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
    }

    /// fx/overlay: floating panels and windows.
    public static func overlay<Content: View>(_ content: Content) -> some View {
        content.shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 6)
    }
}
