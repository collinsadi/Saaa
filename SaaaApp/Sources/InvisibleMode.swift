import AppKit
import Core
import DesignSystem
import SwiftUI

/// Invisible Mode enforcement: every Saaa window registers here once, and
/// `sharingType` is driven from the two defaults keys for as long as the
/// window lives. `.none` defeats software screen capture and conferencing
/// screen share; it does not stop a phone photographing the display, and the
/// settings copy says so.
@MainActor
final class CaptureExclusion {
    static let shared = CaptureExclusion()

    static let enabledKey = "invisibleMode"
    static let scopeKey = "invisibleModeScope"

    private struct Entry {
        weak var window: NSWindow?
        let surface: SaaaSurface
    }

    private var entries: [Entry] = []
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CaptureExclusion.shared.applyAll() }
        }
    }

    func register(_ window: NSWindow, as surface: SaaaSurface) {
        entries.removeAll { $0.window == nil || $0.window === window }
        entries.append(Entry(window: window, surface: surface))
        apply(to: window, surface: surface)
    }

    private func applyAll() {
        entries.removeAll { $0.window == nil }
        for entry in entries {
            guard let window = entry.window else { continue }
            apply(to: window, surface: entry.surface)
        }
    }

    private func apply(to window: NSWindow, surface: SaaaSurface) {
        window.sharingType = InvisibleModePolicy.isExcluded(
            surface, enabled: Self.enabled, scope: Self.scope) ? .none : .readOnly
    }

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var scope: InvisibleModeScope {
        InvisibleModeScope(
            rawValue: UserDefaults.standard.string(forKey: scopeKey) ?? ""
        ) ?? .allWindows
    }
}

/// Registers the hosting NSWindow of a SwiftUI hierarchy. Needed for the
/// Settings scene, whose window SwiftUI creates and owns.
struct WindowRegistrar: NSViewRepresentable {
    let surface: SaaaSurface

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            CaptureExclusion.shared.register(window, as: surface)
        }
    }
}

/// The subtle local indicator: rendered inside windows that are themselves
/// excluded, so only the person at this Mac ever sees it.
struct InvisibleModeBadge: View {
    let surface: SaaaSurface

    @Environment(\.saaa) private var saaa
    @AppStorage(CaptureExclusion.enabledKey) private var enabled = false
    @AppStorage(CaptureExclusion.scopeKey) private var scopeRaw =
        InvisibleModeScope.allWindows.rawValue

    var body: some View {
        if InvisibleModePolicy.isExcluded(
            surface, enabled: enabled,
            scope: InvisibleModeScope(rawValue: scopeRaw) ?? .allWindows)
        {
            HStack(spacing: Space.xs) {
                Image(systemName: "eye.slash")
                Text("Hidden from screen share")
            }
            .font(SaaaFont.caption)
            .foregroundStyle(saaa.textTertiary)
            .accessibilityLabel("This window is hidden from screen recordings and shares")
        }
    }
}
