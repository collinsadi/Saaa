import AppKit
import CallSession
import Core
import DesignSystem
import SwiftUI

/// The hub: Home, Sessions, Playbooks, Settings. While it is open Saaa has
/// a Dock presence; closing it returns Saaa to a menu-bar accessory.
@MainActor
final class HubPresenter {

    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if let window {
            AppPresence.adopt(window)
            WindowFront.present(window)
            return
        }
        let hosting = NSHostingController(rootView: HubView(model: model).saaaThemed())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Saaa"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SaaaHub")
        WindowChrome.applySeamless(to: window)
        if window.frame.origin == .zero { window.center() }
        self.window = window
        ScreenPrivacy.shared.register(window, as: .hub)
        AppPresence.adopt(window)
        WindowFront.present(window)
    }
}

struct HubView: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 560)
    }

    private var sidebar: some View {
        // Rows are tagged with the pane itself (not its id) and the tag is
        // the outermost modifier, so it matches the selection's type exactly.
        List(selection: Binding<HubPane?>(
            get: { model.hubPane },
            set: { if let pane = $0 { model.hubPane = pane } })) {
            ForEach(HubPane.allCases, id: \.self) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .badge(badge(for: pane))
                    .tag(Optional(pane))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: Space.sm) {
                BrandMark(size: 15)
                Text("Saaa").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, 34)
            .padding(.bottom, Space.sm)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Space.sm) {
                if model.session.isBusy {
                    liveCard
                }
                ScreenPrivacyBadge(surface: .hub)
            }
            .padding(Space.md)
        }
    }

    private func badge(for pane: HubPane) -> Int {
        guard pane == .sessions else { return 0 }
        return model.session.summarizing.count + model.session.imports.count
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Lamp(model.session.isLive ? .recording : .processing)
                Text(model.session.isLive ? "Live" : "Saving").engravedLabelStyle()
                    .foregroundStyle(model.session.isLive ? saaa.emberText : saaa.tideText)
                Spacer()
                Text(CallTime.stamp(model.session.callTime))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
            }
            PlaybookBadge(model.session.playbook, compact: true)
            if model.session.isLive {
                HStack {
                    Button("Show panel") {
                        model.panelExpanded = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    Button("Stop") { model.session.stop() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
        .padding(Space.md)
        .saaaGlass(cornerRadius: Radius.control)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.hubPane {
        case .home: HomePane(model: model)
        case .sessions: SessionsPane(model: model)
        case .playbooks: PlaybooksPane(model: model)
        case .settings: SettingsPane(model: model)
        }
    }
}

/// Shared pane header: large title, subtitle, trailing actions.
struct PaneHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
    }
}

extension PaneHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}
