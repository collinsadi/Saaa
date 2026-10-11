/// Screen Privacy: which Saaa surfaces are left out of screen recordings and
/// shared screens (`NSWindow.sharingType = .none`). User-controlled, off by
/// default. Pure policy so it is testable without AppKit.

/// Every window Saaa can put on screen.
public enum SaaaSurface: String, CaseIterable, Sendable {
    /// The black notch bar.
    case island
    /// The glass copilot panel under the island.
    case livePanel
    /// The main window (home, sessions, playbooks, settings).
    case hub
    /// The prep sheet (session context).
    case prep
    case onboarding
    case about
    /// The Code Assist panel (screen text and hints).
    case codeAssist

    /// Surfaces that show call content: transcripts, answers, notes.
    public var carriesCallContent: Bool {
        switch self {
        case .livePanel, .hub, .prep, .codeAssist: true
        case .island, .onboarding, .about: false
        }
    }
}

public enum ScreenPrivacyScope: String, CaseIterable, Sendable {
    /// Every Saaa window.
    case allWindows = "all"
    /// Only windows that show call content.
    case callContent = "content"
}

public enum ScreenPrivacyPolicy {
    /// Storage keys (kept from Invisible Mode so existing choices carry over).
    public static let enabledKey = "invisibleMode"
    public static let scopeKey = "invisibleModeScope"

    /// Standing while the setting is on: never triggered by detecting a
    /// capture, which could flash content into a recording first.
    public static func isExcluded(_ surface: SaaaSurface, enabled: Bool, scope: ScreenPrivacyScope) -> Bool {
        guard enabled else { return false }
        switch scope {
        case .allWindows: return true
        case .callContent: return surface.carriesCallContent
        }
    }
}
