import CallSession
import DesignSystem
import SwiftUI

/// The notch island — Saaa's primary surface. Always dark (it fuses with the
/// hardware), opaque, one kinetic element (the meters). Tiers:
/// dormant (bare notch) → armed → recording compact ⇄ expanded → processing
/// → peek → afterglow, plus error. Click expands; hover never does.
struct IslandRootView: View {
    let controller: CallController
    let metrics: NotchMetrics

    @Environment(\.saaa) private var saaa
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var peekDismissed = false
    @State private var peekHovering = false
    @Namespace private var lampNamespace

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: isRecording) { _, recording in
            if !recording { isExpanded = false }
        }
        .onChange(of: isPeeking) { _, peeking in
            peekDismissed = false
            guard peeking else { return }
            schedulePeekRetract()
        }
    }

    // MARK: - State mapping

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var isPeeking: Bool {
        if case .review = controller.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle, .done:
            // Dormant: the bare notch IS the state. (No-notch Macs hide the
            // capsule entirely when dormant — never a fake notch.)
            EmptyView()
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
                expandedRecordingPanel
                    .transition(.opacity)
            } else {
                compactBar {
                    Lamp(.recording).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                    Text("Rec").engravedLabelStyle().foregroundStyle(saaa.emberText)
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
                bottomLeadingRadius: Radius.lg, bottomTrailingRadius: Radius.lg)
                .fill(saaa.surfaceBase))
        .overlay(
            UnevenRoundedRectangle(
                bottomLeadingRadius: Radius.lg, bottomTrailingRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
        .animation(Motion.standard, value: controller.state)
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
            HStack {
                Lamp(.recording).matchedGeometryEffect(id: "lamp", in: lampNamespace)
                Text("Rec").engravedLabelStyle().foregroundStyle(saaa.emberText)
                Spacer()
                timerReadout(font: SaaaFont.readoutTimer)
            }
            meterRow(label: "Me", level: controller.levels?.mic.rms ?? 0)
            meterRow(label: "Them", level: controller.levels?.system.rms ?? 0)
            HStack {
                Text("local · sealed")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
                Spacer()
                Button {
                    controller.toggle()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(saaa.textOnAccent)
                        .frame(width: Size.controlLg, height: Size.controlLg)
                        .background(Circle().fill(saaa.emberLamp))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
            }
        }
        .padding(Space.lg)
        .padding(.top, metrics.hasNotch ? metrics.topInset : 0)
        .frame(width: Size.Island.expandedWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: Radius.lg, bottomLeadingRadius: Radius.xl,
                bottomTrailingRadius: Radius.xl, topTrailingRadius: Radius.lg)
                .fill(saaa.surfaceBase))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: Radius.lg, bottomLeadingRadius: Radius.xl,
                bottomTrailingRadius: Radius.xl, topTrailingRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
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
                .foregroundStyle(saaa.tideText)
                .frame(width: 38, alignment: .leading)
            LevelBars(level: level, barCount: 24)
                .frame(height: 14)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
    }

    // MARK: - Peek tier

    private var peekPanel: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "tray.full")
                    .foregroundStyle(saaa.tideEmphasis)
                Text(peekTitle)
                    .font(SaaaFont.headline)
                    .foregroundStyle(saaa.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Review") {
                    NSApp.activate()
                    peekDismissed = true
                }
                .buttonStyle(.plain)
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(saaa.textOnAccent)
                .padding(.horizontal, Space.md)
                .frame(height: Size.controlMd)
                .background(Capsule().fill(saaa.tideFill))
            }
            if let judgment = controller.lastJudgment, judgment.match.projectPath != nil {
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
                topLeadingRadius: Radius.lg, bottomLeadingRadius: Radius.xl,
                bottomTrailingRadius: Radius.xl, topTrailingRadius: Radius.lg)
                .fill(saaa.surfaceBase))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: Radius.lg, bottomLeadingRadius: Radius.xl,
                bottomTrailingRadius: Radius.xl, topTrailingRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
        .onHover { peekHovering = $0 } // dwell timer suspends while hovered
    }

    private var peekTitle: String {
        if let path = controller.lastJudgment?.match.projectPath {
            return "Filed to \(URL(filePath: path).lastPathComponent)"
        }
        return "Transcript ready"
    }

    /// Quiet afterglow: a single tide dot below the notch after peek retracts.
    private var afterglowDot: some View {
        Circle()
            .fill(saaa.tideEmphasis)
            .frame(width: 4, height: 4)
            .padding(.top, metrics.topInset + 4)
            .transition(.opacity)
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
