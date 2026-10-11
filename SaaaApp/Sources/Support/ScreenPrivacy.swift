import AppKit
import Core
import DesignSystem
import SwiftUI

/// Screen Privacy enforcement: every Saaa window registers once and its
/// `sharingType` follows the setting for as long as it lives. `.none`
/// keeps a window out of software screen capture and shared screens; it
/// cannot hide anything from a camera pointed at the display.
@MainActor
final class ScreenPrivacy {
    static let shared = ScreenPrivacy()

    private struct Entry {
        weak var window: NSWindow?
        let surface: SaaaSurface
    }

    private var entries: [Entry] = []
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ScreenPrivacy.shared.applyAll() }
        }
    }

    func register(_ window: NSWindow, as surface: SaaaSurface) {
        entries.removeAll { $0.window == nil || $0.window === window }
        entries.append(Entry(window: window, surface: surface))
        apply(to: window, surface: surface)
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: ScreenPrivacyPolicy.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: ScreenPrivacyPolicy.enabledKey) }
    }

    static var scope: ScreenPrivacyScope {
        ScreenPrivacyScope(rawValue: UserDefaults.standard.string(forKey: ScreenPrivacyPolicy.scopeKey) ?? "") ?? .allWindows
    }

    private func applyAll() {
        entries.removeAll { $0.window == nil }
        for entry in entries {
            if let window = entry.window { apply(to: window, surface: entry.surface) }
        }
    }

    private func apply(to window: NSWindow, surface: SaaaSurface) {
        let excluded = ScreenPrivacyPolicy.isExcluded(surface, enabled: Self.enabled, scope: Self.scope)
        window.sharingType = excluded ? .none : .readOnly
    }
}

/// Shown only inside windows that are themselves hidden, so only the person
/// at this Mac ever sees it.
struct ScreenPrivacyBadge: View {
    let surface: SaaaSurface

    @AppStorage(ScreenPrivacyPolicy.enabledKey) private var enabled = false
    @AppStorage(ScreenPrivacyPolicy.scopeKey) private var scopeRaw = ScreenPrivacyScope.allWindows.rawValue

    var body: some View {
        if ScreenPrivacyPolicy.isExcluded(surface, enabled: enabled, scope: ScreenPrivacyScope(rawValue: scopeRaw) ?? .allWindows) {
            Label("Hidden from screen sharing", systemImage: "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("This window is hidden from screen recordings and shares")
        }
    }
}
