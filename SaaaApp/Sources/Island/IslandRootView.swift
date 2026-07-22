import AgentBridge
import CallSession
import DesignSystem
import SwiftUI

/// The notch island — Saaa's primary surface. Always dark (it fuses with the
/// hardware), opaque, one kinetic element (the meters). Tiers:
/// dormant (bare notch) → armed → recording compact ⇄ expanded → processing
/// → peek → afterglow, plus error. Click expands; hover never does.
/// Hairline on the island's sides and bottom ONLY — no top edge, so the
/// island reads as attached to (growing out of) the notch.
private struct IslandOpenBorder: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

struct IslandRootView: View {
    let controller: CallController
    let metrics: NotchMetrics
    let outsideClick: OutsideClickSignal
    let welcome: WelcomePulse

    @Environment(\.saaa) private var saaa
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showIsland") private var showIsland = true
    @AppStorage("freezeMeters") private var freezeMeters = false
    @State private var isExpanded = false
    @State private var peekDismissed = false
    @State private var peekHovering = false
    @State private var askText = ""
    @Namespace private var lampNamespace

    var body: some View {
        VStack(spacing: 0) {
            content
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.4, anchor: .top).combined(with: .opacity))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(Motion.expand(reduceMotion: reduceMotion), value: tierID)
        .onChange(of: isRecording) { _, recording in
            if !recording { isExpanded = false }
        }
        .onChange(of: outsideClick.count) { _, _ in
            guard isExpanded else { return }
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) {
                isExpanded = false
            }
        }
        .onChange(of: isPeeking) { _, peeking in
            peekDismissed = false
            guard peeking else { return }
            schedulePeekRetract()
        }
    }

    /// Coarse tier discriminator — drives morph animations without
    /// retriggering on timer/level updates. Queue work and ready reviews
    /// surface during idle: the state machine frees up the moment a
    /// recording stops, but the island still narrates the background.
    private var tierID: String {
        if welcome.active, case .idle = controller.state { return "welcome" }
        return switch controller.state {
        case .idle, .done:
            controller.queueBusy
                ? "processing"
                : (controller.hasReadyReview ? (peekDismissed ? "afterglow" : "peek") : "dormant")
        case .armed: "armed"
        case .recording: isExpanded ? "rec-expanded" : "rec-compact"
        case .processing: "processing"
        case .review: peekDismissed ? "afterglow" : "peek"
        case .error: "error"
        }
    }

    // MARK: - State mapping

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var isPeeking: Bool {
        controller.hasReadyReview
    }

    @ViewBuilder
    private var content: some View {
        if !showIsland {
            EmptyView()
        } else {
            tieredContent
        }
    }

    @ViewBuilder
    private var tieredContent: some View {
        switch controller.state {
        case .idle, .done:
            // Dormant: the bare notch IS the state. (No-notch Macs hide the
            // capsule entirely when dormant — never a fake notch.) The
            // background queue narrates here: filing bar while jobs run,
            // peek when a processed call awaits review.
            if welcome.active {
                welcomePanel
            } else if controller.queueBusy {
                compactBar {
                    Lamp(.processing).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                    Text("Filing").engravedLabelStyle().foregroundStyle(saaa.tideText)
                } trailing: {
                    Text(shortProcessingDetail)
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.textTertiary)
                        .lineLimit(1)
                }
            } else if controller.hasReadyReview {
                if peekDismissed {
                    afterglowDot
                } else {
                    peekPanel
                }
            } else {
                EmptyView()
            }
        case .armed:
            compactBar {
                Lamp(.armed).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                Text("Armed").engravedLabelStyle().foregroundStyle(saaa.emberText)
            } trailing: {
                Text("00:00")
                    .font(SaaaFont.readoutValue)
                    .foregroundStyle(saaa.textTertiary)
            }
        case .recording:
            if isExpanded {
                if controller.liveAssist.phase != .off {
                    assistPanel
                        .transition(.opacity)
                } else {
                    expandedRecordingPanel
                        .transition(.opacity)
                }
            } else {
                compactBar {
                    Lamp(.recording).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                    Text("Rec").engravedLabelStyle().foregroundStyle(saaa.emberText)
                    if controller.liveAssist.phase != .off {
                        // "Show clearly when the mode is live" (issue #8).
                        // A state label, not a control — reads as a readout.
                        Text("AI")
                            .engravedLabelStyle()
                            .foregroundStyle(saaa.textSecondary)
                    }
                } trailing: {
                    timerReadout(font: SaaaFont.readoutValue)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.expand(reduceMotion: reduceMotion)) {
                        isExpanded = true
                    }
                }
            }
        case .processing:
            compactBar {
                Lamp(.processing).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                Text("Filing").engravedLabelStyle().foregroundStyle(saaa.tideText)
            } trailing: {
                Text(shortProcessingDetail)
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
                    .lineLimit(1)
            }
        case .review:
            if peekDismissed {
                afterglowDot
            } else {
                peekPanel
            }
        case .error:
            compactBar {
                Lamp(.error).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                Text("Error").engravedLabelStyle().foregroundStyle(saaa.dangerText)
            } trailing: {
                Text("menu ↗")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
        }
    }

    // MARK: - Compact tier

    /// The compact bar hugging the notch: content lives in the flanks, the
    /// notch dead-zone stays empty. Bottom corners only — the top edge fuses
    /// with the bezel.
    private func compactBar(
        @ViewBuilder leading: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                leading()
            }
            .padding(.leading, Space.md)
            .frame(width: Size.Island.flankWidth, alignment: .leading)
            Color.clear
                .frame(width: max(metrics.notchWidth, 2))
            HStack {
                trailing()
            }
            .padding(.trailing, Space.md)
            .frame(width: Size.Island.flankWidth, alignment: .trailing)
        }
        .frame(height: barHeight)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: Size.Island.compactRadius,
                bottomTrailingRadius: Size.Island.compactRadius)
                .fill(SaaaPalette.islandSurface))
        .overlay(
            IslandOpenBorder(cornerRadius: Size.Island.compactRadius)
                .stroke(saaa.borderHairline.opacity(0.6), lineWidth: 1))
    }

    // MARK: - Assist tier (the continuous copilot, UI-PLAN §4.7 addendum)

    /// The Live Assist tier: a per-call thread — asks, mode triggers, and
    /// answers accumulate for as long as the call runs. Header chrome and
    /// the ask field stay pinned; only the thread scrolls. No tap-to-collapse
    /// (interactive content everywhere); outside click still collapses.
    private var assistPanel: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Lamp(.recording).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                Text("Rec").engravedLabelStyle().foregroundStyle(saaa.emberText)
                timerReadout(font: SaaaFont.readoutValue)
                Spacer()
                Text("Live Assist · Streaming")
                    .engravedLabelStyle()
                    .foregroundStyle(saaa.tideText)
                Spacer()
                Toggle(isOn: Binding(
                    get: { controller.micMuted },
                    set: { controller.setMicMuted($0) }
                )) {
                    Text("Mute")
                        .font(SaaaFont.caption)
                        .foregroundStyle(saaa.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(saaa.tideFill)
                Button {
                    controller.toggle()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(saaa.textOnAccent)
                        .frame(width: Size.controlMd, height: Size.controlMd)
                        .background(Circle().fill(saaa.emberLamp))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
            }
            threadView
            Text("suggestions, say them your way · thread seals with the call")
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.textTertiary)
            modeRow
            askField
        }
        .padding(Space.lg)
        .padding(.top, metrics.hasNotch ? metrics.topInset : 0)
        .frame(width: Size.Island.assistWidth)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: Size.Island.expandedRadius,
                bottomTrailingRadius: Size.Island.expandedRadius)
                .fill(SaaaPalette.islandSurface))
        .overlay(
            IslandOpenBorder(cornerRadius: Size.Island.expandedRadius)
                .stroke(saaa.borderHairline.opacity(0.6), lineWidth: 1))
    }

    private var threadView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if controller.liveAssist.thread.isEmpty,
                       controller.liveAssist.pendingMode == nil {
                        Text("Ask anything, any time.")
                            .font(SaaaFont.headline)
                            .foregroundStyle(saaa.textPrimary)
                        Text("Answers land here for as long as the call runs.")
                            .font(SaaaFont.callout)
                            .foregroundStyle(saaa.textSecondary)
                    }
                    ForEach(controller.liveAssist.thread) { exchange in
                        threadEntry(exchange).id(exchange.id)
                    }
                    if let pending = controller.liveAssist.pendingMode {
                        HStack(spacing: Space.sm) {
                            Text(pending.displayName)
                                .font(SaaaFont.monoCaption)
                                .foregroundStyle(saaa.tideText)
                            Text("drafting from the last 30 seconds …")
                                .font(SaaaFont.monoCaption)
                                .foregroundStyle(saaa.textTertiary)
                        }
                        .id("drafting")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 132)
            .onChange(of: controller.liveAssist.thread.count) {
                guard let last = controller.liveAssist.thread.last else { return }
                if reduceMotion {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation(Motion.standard) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func threadEntry(_ exchange: LiveAssistExchange) -> some View {
        switch exchange.kind {
        case .ask(let text):
            HStack {
                Spacer(minLength: Space.huge)
                Text(text)
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md + 6).fill(saaa.surfaceInset))
            }
        case .answer(let mode, let text):
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(mode.displayName)
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.tideText)
                    Text(exchange.at.formatted(date: .omitted, time: .shortened))
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.textTertiary)
                }
                Text(text)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            Text(message)
                .font(SaaaFont.caption)
                .foregroundStyle(saaa.dangerText)
                .lineLimit(2)
        }
    }

    private var modeRow: some View {
        HStack(spacing: Space.sm) {
            ForEach(Array(AssistMode.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 {
                    Text("·")
                        .font(SaaaFont.callout)
                        .foregroundStyle(saaa.textTertiary)
                }
                Button(mode.displayName) {
                    controller.liveAssist.trigger(mode)
                }
                .buttonStyle(.plain)
                .font(SaaaFont.callout)
                .foregroundStyle(
                    controller.liveAssist.pendingMode == mode
                        ? saaa.tideText : saaa.textSecondary)
            }
            Spacer()
        }
    }

    private var askField: some View {
        HStack(spacing: Space.sm) {
            TextField("Ask about the call", text: $askText)
                .textFieldStyle(.plain)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textPrimary)
                .onSubmit { submitAsk() }
            if askText.isEmpty {
                Text("⌘↩ for Assist")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
            Button {
                submitAsk()
            } label: {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(saaa.textOnAccent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(saaa.tideFill))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Radius.md + 6).fill(saaa.surfaceInset))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md + 6)
                .strokeBorder(saaa.borderHairline.opacity(0.6), lineWidth: 1))
    }

    private func submitAsk() {
        let text = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        askText = ""
        if text.isEmpty {
            controller.liveAssist.trigger(.assist)
        } else {
            controller.liveAssist.ask(text)
        }
    }

    /// Tall enough to clear the notch on any model; below the menu bar on
    /// no-notch Macs (fallback capsule, never a fake notch).
    private var barHeight: CGFloat {
        metrics.hasNotch
            ? max(Size.Island.barHeight, metrics.topInset + 6)
            : Size.Island.barHeight
    }

    // MARK: - Expanded tier (H7)

    private var expandedRecordingPanel: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Recorder grammar: the stop control sits in the header beside
            // the timer readout.
            HStack(spacing: Space.sm) {
                Lamp(.recording).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                Text("Rec").engravedLabelStyle().foregroundStyle(saaa.emberText)
                Spacer()
                timerReadout(font: SaaaFont.readoutTimer)
                Button {
                    controller.toggle()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(saaa.textOnAccent)
                        .frame(width: Size.controlMd, height: Size.controlMd)
                        .background(Circle().fill(saaa.emberLamp))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
            }
            meterRow(label: "Me", level: controller.micMuted ? 0 : (controller.levels?.mic.rms ?? 0))
            meterRow(label: "Them", level: controller.levels?.system.rms ?? 0)
            HStack(spacing: Space.sm) {
                Toggle(isOn: Binding(
                    get: { controller.micMuted },
                    set: { controller.setMicMuted($0) }
                )) {
                    Text("Mute my mic")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(saaa.tideFill)
                Spacer()
                // Only truthful while nothing streams (issue #8 consent fix).
                if controller.liveAssist.phase == .off {
                    Text("local · sealed")
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.textTertiary)
                }
            }
        }
        .padding(Space.lg)
        .padding(.top, metrics.hasNotch ? metrics.topInset : 0)
        .frame(width: Size.Island.expandedWidth)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: Size.Island.expandedRadius,
                bottomTrailingRadius: Size.Island.expandedRadius)
                .fill(SaaaPalette.islandSurface))
        .overlay(
            IslandOpenBorder(cornerRadius: Size.Island.expandedRadius)
                .stroke(saaa.borderHairline.opacity(0.6), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) {
                isExpanded = false
            }
        }
    }

    private func meterRow(label: String, level: Float) -> some View {
        HStack(spacing: Space.md) {
            Text(label)
                .engravedLabelStyle()
                .foregroundStyle(saaa.textSecondary)
                .frame(width: 38, alignment: .leading)
            LevelBars(level: level, barCount: 24, frozen: freezeMeters)
                .frame(height: 14)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
    }

    // MARK: - Welcome tier

    /// The post-onboarding hello: grows out of the notch, teaches the
    /// hotkey, then retreats into it after a dwell (the retreat teaches
    /// where Saaa lives). Click dismisses immediately.
    private var welcomePanel: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                BrandMark(size: 18)
                Text("Saaa lives here")
                    .font(SaaaFont.headline)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
                Text("⌥⌘R")
                    .font(SaaaFont.readoutValue)
                    .foregroundStyle(saaa.tideEmphasis)
                    .padding(.horizontal, Space.sm)
                    .frame(height: Size.controlSm)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(saaa.borderControl, lineWidth: 1))
            }
            HStack(spacing: Space.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(saaa.tideEmphasis)
                Text("Press it during a call. Records, files, retreats.")
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
            }
            .transition(.opacity)
        }
        .padding(Space.lg)
        .padding(.top, metrics.hasNotch ? metrics.topInset : 0)
        .frame(width: Size.Island.expandedWidth)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: Size.Island.expandedRadius,
                bottomTrailingRadius: Size.Island.expandedRadius)
                .fill(SaaaPalette.islandSurface))
        .overlay(
            IslandOpenBorder(cornerRadius: Size.Island.expandedRadius)
                .stroke(saaa.borderHairline.opacity(0.6), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) {
                welcome.dismiss()
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(10))
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) {
                welcome.dismiss()
            }
        }
    }

    // MARK: - Peek tier

    private var peekPanel: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "tray.full")
                    .foregroundStyle(saaa.textSecondary)
                Text(peekTitle)
                    .font(SaaaFont.headline)
                    .foregroundStyle(saaa.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Review") {
                    controller.openLatestReadyReview()
                    peekDismissed = true
                }
                .buttonStyle(.plain)
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(saaa.textOnAccent)
                .padding(.horizontal, Space.md)
                .frame(height: Size.controlMd)
                .background(Capsule().fill(saaa.tideFill))
            }
            if let judgment = controller.lastJudgment, judgment.isConfident {
                Text("confidence \(Int(judgment.match.confidence * 100))% · \(judgment.callType.replacingOccurrences(of: "_", with: " "))")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
        }
        .padding(Space.lg)
        .padding(.top, metrics.hasNotch ? metrics.topInset : 0)
        .frame(width: Size.Island.expandedWidth)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: Size.Island.expandedRadius,
                bottomTrailingRadius: Size.Island.expandedRadius)
                .fill(SaaaPalette.islandSurface))
        .overlay(
            IslandOpenBorder(cornerRadius: Size.Island.expandedRadius)
                .stroke(saaa.borderHairline.opacity(0.6), lineWidth: 1))
        .onHover { peekHovering = $0 } // dwell timer suspends while hovered
    }

    private var peekTitle: String {
        if let judgment = controller.lastJudgment, judgment.isConfident,
           let path = judgment.match.projectPath {
            return "Filed to \(URL(filePath: path).lastPathComponent)"
        }
        return "Transcript ready, unfiled"
    }

    /// Quiet afterglow: a single tide dot below the notch after peek
    /// retracts. Tapping it reopens the peek — the tideEmphasis is earned.
    private var afterglowDot: some View {
        Circle()
            .fill(saaa.tideEmphasis)
            .frame(width: 4, height: 4)
            .padding(Space.md)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.expand(reduceMotion: reduceMotion)) {
                    peekDismissed = false
                }
                schedulePeekRetract()
            }
            .padding(.top, metrics.topInset - Space.md + 4)
            .transition(.opacity)
            .accessibilityLabel("Reopen the ready review")
            .accessibilityAddTraits(.isButton)
    }

    private func schedulePeekRetract() {
        Task { @MainActor in
            var elapsed: TimeInterval = 0
            while elapsed < Motion.peekDwell {
                try? await Task.sleep(for: .milliseconds(250))
                guard isPeeking, !peekDismissed else { return }
                if !peekHovering { elapsed += 0.25 }
            }
            withAnimation(Motion.collapse(reduceMotion: reduceMotion)) {
                peekDismissed = true
            }
        }
    }

    // MARK: - Shared pieces

    private func timerReadout(font: Font) -> some View {
        Text(timerText)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(saaa.textPrimary)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(Motion.standard, value: timerText)
    }

    private var timerText: String {
        let seconds = Int(controller.levels?.time ?? 0)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    private var shortProcessingDetail: String {
        let detail = controller.processingDetail
        if detail.hasPrefix("Downloading") { return "model…" }
        if detail.hasPrefix("Transcribing") { return "whisper…" }
        if detail.hasPrefix("Asking") { return "claude…" }
        if detail.hasPrefix("Matching") { return "match…" }
        if detail.hasPrefix("Securing") { return "sealing…" }
        return "…"
    }
}
