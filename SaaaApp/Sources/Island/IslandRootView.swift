import CallSession
import Core
import DesignSystem
import SwiftUI

/// Hairline on the island's sides and bottom only: no top edge, so every
/// tier reads as the notch itself growing.
private struct IslandOpenBorder: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Saaa's always-there surface. The black island fuses with the notch
/// (compact bar, plus short black tiers for suggestions and results); the
/// Liquid Glass copilot panel floats just below it during a call.
struct IslandRootView: View {
    @Bindable var model: AppModel
    let metrics: NotchMetrics
    let outsideClick: OutsideClickSignal
    let welcome: WelcomePulse

    @Environment(\.saaa) private var saaa
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SaaaSettings.showIslandKey) private var showIsland = true
    @AppStorage(SaaaSettings.freezeMetersKey) private var freezeMeters = false
    @State private var readyDismissed = false
    @State private var readyHovering = false

    private var session: SessionController { model.session }

    var body: some View {
        VStack(spacing: Space.sm) {
            if showIsland {
                island
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                if session.isLive, model.panelExpanded {
                    LivePanel(model: model)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.expand(reduceMotion: reduceMotion), value: tier)
        .animation(Motion.expand(reduceMotion: reduceMotion), value: model.panelExpanded)
        .onChange(of: outsideClick.count) { _, _ in
            guard model.panelExpanded else { return }
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) { model.panelExpanded = false }
        }
        .onChange(of: session.isLive) { _, live in
            if !live { model.panelExpanded = false }
        }
        .onChange(of: session.readySummary?.id) { _, id in
            readyDismissed = false
            if id != nil { scheduleReadyRetract() }
        }
    }

    // MARK: - Tiers

    private enum Tier: Hashable {
        case hidden, welcome, suggestion, starting, live, finishing, failed, ready, background
    }

    private var tier: Tier {
        switch session.phase {
        case .starting: return .starting
        case .live: return .live
        case .finishing: return .finishing
        case .failed: return .failed
        case .idle: break
        }
        if welcome.active { return .welcome }
        if model.detector.suggestion != nil { return .suggestion }
        if session.readySummary != nil, !readyDismissed { return .ready }
        if !session.summarizing.isEmpty || !session.imports.isEmpty { return .background }
        return .hidden
    }

    @ViewBuilder
    private var island: some View {
        switch tier {
        case .hidden:
            EmptyView()
        case .welcome:
            welcomeTier
        case .suggestion:
            suggestionTier
        case .starting:
            compactBar {
                Lamp(.armed)
                Text("Starting").engravedLabelStyle().foregroundStyle(saaa.emberText)
            } trailing: {
                ProgressView().controlSize(.mini)
            }
        case .live:
            liveBar
        case .finishing:
            compactBar {
                Lamp(.processing)
                Text("Saving").engravedLabelStyle().foregroundStyle(saaa.tideText)
            } trailing: {
                Text("sealing…").font(SaaaFont.monoCaption).foregroundStyle(saaa.textTertiary)
            }
        case .failed:
            failedTier
        case .ready:
            readyTier
        case .background:
            compactBar {
                Lamp(.processing)
                Text(session.imports.isEmpty ? "Summary" : "Import").engravedLabelStyle().foregroundStyle(saaa.tideText)
            } trailing: {
                Text("writing…").font(SaaaFont.monoCaption).foregroundStyle(saaa.textTertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.openHub(.sessions) }
        }
    }

    // MARK: - Live bar

    private var liveBar: some View {
        compactBar {
            Lamp(.recording)
            Text("Rec").engravedLabelStyle().foregroundStyle(saaa.emberText)
            Text(CallTime.stamp(session.callTime))
                .font(SaaaFont.readoutValue)
                .monospacedDigit()
                .foregroundStyle(saaa.textPrimary)
                .contentTransition(reduceMotion ? .identity : .numericText())
        } trailing: {
            HStack(spacing: 6) {
                if session.copilot?.isStreaming == true {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(saaa.tideEmphasis)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                } else if session.copilot?.pendingQuestion != nil {
                    Circle().fill(saaa.tideEmphasis).frame(width: 6, height: 6)
                        .accessibilityLabel("They asked a question")
                }
                LevelBars(
                    level: max(session.micMuted ? 0 : (session.levels?.mic.rms ?? 0), session.levels?.system.rms ?? 0),
                    barCount: 10, frozen: freezeMeters)
                    .frame(width: 34, height: 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.expand(reduceMotion: reduceMotion)) { model.panelExpanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording, \(CallTime.stamp(session.callTime)). Click to open the copilot.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Expanded black tiers

    private var suggestionTier: some View {
        expandedTier {
            HStack(spacing: Space.sm) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(saaa.tideEmphasis)
                Text("Meeting starting").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
                Spacer()
                KeyCap("⌥⌘R")
            }
            if let suggestion = model.detector.suggestion {
                Text(suggestion.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(saaa.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Space.sm) {
                    if let event = suggestion.event,
                       let playbook = PlaybookMatcher.match(title: event.title, in: model.playbooks.all) {
                        PlaybookBadge(playbook, compact: true)
                    } else {
                        PlaybookBadge(model.playbooks.defaultPlaybook, compact: true)
                    }
                    Text("· \(suggestion.source)")
                        .font(.system(size: 11))
                        .foregroundStyle(saaa.textTertiary)
                    Spacer()
                    Button("Not now") { model.detector.dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(saaa.textSecondary)
                    Button {
                        model.startSuggested()
                    } label: {
                        Label("Start", systemImage: "record.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(saaa.tideFill))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var failedTier: some View {
        expandedTier {
            HStack(spacing: Space.sm) {
                Lamp(.error)
                Text("Couldn't start").engravedLabelStyle().foregroundStyle(saaa.dangerText)
            }
            if case .failed(let message) = session.phase {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(saaa.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Dismiss") { session.clearFailure() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.textSecondary)
                Button("Try again") { model.toggleSession() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(saaa.tideFill))
                    .foregroundStyle(.white)
            }
        }
    }

    private var readyTier: some View {
        expandedTier {
            HStack(spacing: Space.sm) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(saaa.successText)
                Text("Summary ready").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
                Spacer()
                Button {
                    session.dismissReadySummary()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(saaa.textTertiary)
                .accessibilityLabel("Dismiss")
            }
            if let entry = session.readySummary {
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(saaa.textPrimary)
                    .lineLimit(1)
                if !entry.tldr.isEmpty {
                    Text(entry.tldr)
                        .font(.system(size: 12))
                        .foregroundStyle(saaa.textSecondary)
                        .lineLimit(2)
                }
                HStack {
                    if entry.openActionItems > 0 {
                        Label("\(entry.openActionItems) action item\(entry.openActionItems == 1 ? "" : "s")", systemImage: "checklist")
                            .font(.system(size: 11))
                            .foregroundStyle(saaa.textTertiary)
                    }
                    Spacer()
                    Button {
                        model.openSession(entry.id)
                        session.dismissReadySummary()
                    } label: {
                        Text("Open")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 26)
                            .background(Capsule().fill(saaa.tideFill))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onHover { readyHovering = $0 }
    }

    private var welcomeTier: some View {
        expandedTier {
            HStack(spacing: Space.md) {
                BrandMark(size: 18)
                Text("Saaa lives here")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
                KeyCap("⌥⌘R")
            }
            Text("Start Saaa when a call begins. ⌥⌘A answers what they just asked, ⌥⌘K asks anything.")
                .font(.system(size: 12))
                .foregroundStyle(saaa.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.collapse(reduceMotion: reduceMotion)) { welcome.dismiss() } }
        .task {
            try? await Task.sleep(for: .seconds(10))
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) { welcome.dismiss() }
        }
    }

    private func scheduleReadyRetract() {
        Task { @MainActor in
            var elapsed: TimeInterval = 0
            while elapsed < 12 {
                try? await Task.sleep(for: .milliseconds(250))
                guard session.readySummary != nil, !readyDismissed else { return }
                if !readyHovering { elapsed += 0.25 }
            }
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) { readyDismissed = true }
        }
    }

    // MARK: - Shapes

    private var barHeight: CGFloat {
        metrics.hasNotch ? max(Size.Island.barHeight, metrics.topInset + 6) : Size.Island.barHeight
    }

    /// The compact bar hugging the notch: content in the flanks, the notch
    /// dead zone empty, bottom corners only.
    private func compactBar(
        @ViewBuilder leading: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: Space.sm) { leading() }
                .padding(.leading, Space.md)
                .frame(width: 140, alignment: .leading)
            Color.clear.frame(width: max(metrics.notchWidth, 2))
            HStack(spacing: Space.sm) { trailing() }
                .padding(.trailing, Space.md)
                .frame(width: 140, alignment: .trailing)
        }
        .frame(height: barHeight)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: Size.Island.compactRadius, bottomTrailingRadius: Size.Island.compactRadius)
                .fill(SaaaPalette.islandSurface))
        .overlay(IslandOpenBorder(cornerRadius: Size.Island.compactRadius).stroke(saaa.borderHairline.opacity(0.6), lineWidth: 1))
    }

    /// A short black tier grown out of the notch.
    private func expandedTier(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            content()
        }
        .padding(Space.lg)
        .padding(.top, metrics.hasNotch ? metrics.topInset : 0)
        .frame(width: Size.Island.expandedWidth + 20)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: Size.Island.expandedRadius, bottomTrailingRadius: Size.Island.expandedRadius)
                .fill(SaaaPalette.islandSurface))
        .overlay(IslandOpenBorder(cornerRadius: Size.Island.expandedRadius).stroke(saaa.borderHairline.opacity(0.6), lineWidth: 1))
    }
}
