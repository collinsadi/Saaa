/// Invisible Mode (issue #5): which Saaa surfaces are excluded from screen
/// capture and screen share. The decision is pure so it can be tested without
/// AppKit; the app maps the verdict onto `NSWindow.sharingType`.

/// Every window Saaa can put on screen.
public enum SaaaSurface: String, CaseIterable, Sendable {
    case island
    case review
    case history
    case settings
    case onboarding

    /// Surfaces that display call content: transcripts, matches, extracted
    /// context. These stay hidden even under the narrower scope.
    public var carriesCallContent: Bool {
        switch self {
        case .review, .history: true
        case .island, .settings, .onboarding: false
        }
    }
}

/// What Invisible Mode covers: every Saaa window, or only the ones that
/// show call content (so benign parts can still be shared with the room).
public enum InvisibleModeScope: String, CaseIterable, Sendable {
    case allWindows = "all"
    case callContent = "content"
}

public enum InvisibleModePolicy {
    /// Exclusion is standing while the setting is on, never triggered by
    /// capture detection, which can flash the UI into a recording first.
    public static func isExcluded(
        _ surface: SaaaSurface, enabled: Bool, scope: InvisibleModeScope
    ) -> Bool {
        guard enabled else { return false }
        switch scope {
        case .allWindows: return true
        case .callContent: return surface.carriesCallContent
        }
    }
}
