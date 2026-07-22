import AppKit
import Core
import DesignSystem
import SwiftUI

/// About Saaa (UI-PLAN §4.8): brand, version, and the consent posture in one
/// calm plate. Lives in the menu-bar menu because Saaa is accessory-first —
/// the main menu is unreachable exactly when the hub is closed.
@MainActor
final class AboutPresenter {

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView().saaaThemed())
            let window = NSWindow(contentViewController: hosting)
            window.title = "About Saaa"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            WindowChrome.applySeamless(to: window)
            window.center()
            CaptureExclusion.shared.register(window, as: .settings)
            self.window = window
        }
        if let window {
            WindowFront.present(window)
        }
    }
}

private struct AboutView: View {
    @Environment(\.saaa) private var saaa

    private var version: String {
        let short = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: Space.md) {
            BrandMark(size: 44)
                .padding(.top, Space.lg)
            Text("Saaa")
                .font(SaaaFont.title1)
                .foregroundStyle(saaa.textPrimary)
            Text("Every call, in context")
                .font(SaaaFont.callout)
                .foregroundStyle(saaa.textSecondary)
            Text(version)
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.textTertiary)
            Divider()
                .overlay(saaa.borderHairline)
                .frame(width: 180)
                .padding(.vertical, Space.sm)
            Text("Records only when you start it. Transcribed and sealed on this Mac.")
                .font(SaaaFont.callout)
                .foregroundStyle(saaa.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xxxl)
        .frame(width: 300)
        .background(saaa.surfaceBase.ignoresSafeArea())
    }
}
