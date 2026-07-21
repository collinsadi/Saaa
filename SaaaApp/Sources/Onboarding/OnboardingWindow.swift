import AppKit
import DesignSystem
import SwiftUI

/// First-run bootstrap: brand header, segmented step meter, short copy,
/// status chips, capsule CTAs. Calm and quick.
@MainActor
final class OnboardingPresenter {

    private var window: NSWindow?

    func show(onFinish: @escaping @MainActor () -> Void) {
        let view = OnboardingView(onFinish: { [weak self] in
            self?.window?.close()
            self?.window = nil
            onFinish()
        })
        .saaaThemed()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Saaa"
        window.setContentSize(NSSize(width: 540, height: 600))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    let onFinish: @MainActor () -> Void

    @Environment(\.saaa) private var saaa
    @State private var model = OnboardingModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header
            stepBody
                .transition(.opacity)
                .id(model.step)
            Spacer(minLength: 0)
            footer
        }
        .padding(Space.xxl)
        .frame(width: 540, height: 600)
        .background(saaa.surfaceBase)
        .animation(Motion.standard, value: model.step)
        .onAppear { model.refresh() }
    }

    // MARK: - Header: brand + step meter

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                BrandMark(size: 22)
                Text("Saaa")
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
                Text("0\(model.step + 1) / 0\(model.stepCount)")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
            stepMeter
        }
    }

    /// Segmented progress meter in the design system's meter language:
    /// finished and current segments fill tide, upcoming stay inset.
    private var stepMeter: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<model.stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= model.step ? saaa.tideFill : saaa.surfaceInset)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if index == model.step {
                            Capsule().stroke(saaa.tideEmphasis.opacity(0.5), lineWidth: 1)
                        }
                    }
            }
        }
        .animation(Motion.standard, value: model.step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(model.step + 1) of \(model.stepCount)")
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case 0: welcome
        case 1: permissions
        case 2: transcription
        default: claude
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            titleBlock(
                "Every call, in context",
                "Press ⌥⌘R during a call. Saaa records, transcribes, and files it into the right project.")
            infoCard(
                icon: "lock.shield.fill",
                title: "Private by design",
                body: "Everything runs on this Mac. Audio is deleted after transcription.")
            infoCard(
                icon: "person.2.wave.2.fill",
                title: "Consent matters",
                body: "Recording laws vary. Saaa always shows a visible indicator. Telling people is on you.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            titleBlock("Saaa listens only while you record", nil)
            statusCard(
                icon: "mic.fill", title: "Microphone",
                body: "Your side of the call.",
                status: model.micStatus,
                action: ("Grant", { model.requestMicrophone() }))
            statusCard(
                icon: "speaker.wave.2.fill", title: "System audio",
                body: "The other side. macOS needs a one-time manual grant in the lower list of the Settings pane.",
                status: model.systemAudioStatus,
                action: ("Open Settings", { model.openSystemAudioSettings() }),
                secondaryAction: ("Verify", { model.verifySystemAudio() }),
                footnote: model.systemAudioBlocked
                    ? "Toggle on but still blocked? Quit Saaa, open it again from Applications, then verify."
                    : nil)
            statusCard(
                icon: "calendar", title: "Calendar",
                body: "Optional. The event during a call helps filing.",
                status: model.calendarStatus,
                action: ("Grant", { model.requestCalendar() }))
        }
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            titleBlock(
                "Transcription stays on this Mac",
                "Whisper runs locally. One download, cached forever.")
            statusCard(
                icon: "waveform", title: "Whisper model",
                body: "large-v3-turbo plus voice detection.",
                status: model.modelStatus,
                action: ("Download", { model.downloadModels() }))
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            titleBlock(
                "Your Claude Code files the call",
                "Runs under your subscription. Writes only what you approve.")
            statusCard(
                icon: "terminal.fill", title: "claude CLI",
                body: "Read-only for matching.",
                status: model.claudeStatus,
                action: ("Check", { model.checkClaude() }))
            infoCard(
                icon: "tray.fill",
                title: "Works without it",
                body: "Calls simply stay unfiled until Claude Code is ready.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Space.md) {
            if model.step > 0 {
                Button {
                    model.step -= 1
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                if model.step < model.stepCount - 1 {
                    model.step += 1
                    model.refresh()
                } else {
                    onFinish()
                }
            } label: {
                HStack(spacing: Space.sm) {
                    if model.step == model.stepCount - 1 {
                        BrandMark(size: 13, ink: saaa.textOnAccent, ember: saaa.textOnAccent)
                        Text("Start using Saaa")
                    } else {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(saaa.textOnAccent)
                .padding(.horizontal, Space.xl)
                .frame(height: 34)
                .background(Capsule().fill(saaa.tideFill))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Building blocks

    private func titleBlock(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(SaaaFont.title1)
                .foregroundStyle(saaa.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iconChip(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(saaa.tideEmphasis)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceInset))
    }

    private func infoCard(icon: String, title: String, body bodyText: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            iconChip(icon)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(SaaaFont.headline)
                    .foregroundStyle(saaa.textPrimary)
                Text(bodyText)
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
    }

    private func statusCard(
        icon: String, title: String, body bodyText: String,
        status: OnboardingModel.StepStatus,
        action: (String, @MainActor () -> Void)? = nil,
        secondaryAction: (String, @MainActor () -> Void)? = nil,
        footnote: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            iconChip(icon)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text(title)
                        .font(SaaaFont.headline)
                        .foregroundStyle(saaa.textPrimary)
                    Spacer()
                    statusChip(status)
                }
                Text(bodyText)
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showActions(for: status) {
                    HStack(spacing: Space.sm) {
                        if let action {
                            smallButton(action.0, prominent: secondaryAction == nil, action: action.1)
                        }
                        if let secondaryAction {
                            smallButton(secondaryAction.0, prominent: true, action: secondaryAction.1)
                        }
                    }
                }
                if let footnote {
                    Text(footnote)
                        .font(SaaaFont.caption)
                        .foregroundStyle(saaa.emberText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
    }

    private func showActions(for status: OnboardingModel.StepStatus) -> Bool {
        switch status {
        case .granted, .working: false
        default: true
        }
    }

    /// Status chip: icon + word, colored by the state grammar.
    @ViewBuilder
    private func statusChip(_ status: OnboardingModel.StepStatus) -> some View {
        switch status {
        case .unknown:
            EmptyView()
        case .working(let word):
            chip(word, icon: nil, color: saaa.tideText, spinner: true)
        case .granted(let word):
            chip(word, icon: "checkmark.circle.fill", color: saaa.successText)
        case .pending(let word):
            chip(word, icon: "circle.dashed", color: saaa.textTertiary)
        case .denied(let word):
            chip(word, icon: "exclamationmark.circle.fill", color: saaa.dangerText)
        }
    }

    private func chip(
        _ word: String, icon: String?, color: Color, spinner: Bool = false
    ) -> some View {
        HStack(spacing: Space.xs) {
            if spinner {
                ProgressView().controlSize(.mini)
            }
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(word).font(SaaaFont.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, Space.sm)
        .frame(height: 22)
        .background(Capsule().fill(saaa.surfaceInset))
    }

    private func smallButton(
        _ title: String, prominent: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(prominent ? saaa.textOnAccent : saaa.tideText)
                .padding(.horizontal, Space.md)
                .frame(height: 28)
                .background {
                    if prominent {
                        Capsule().fill(saaa.tideFill)
                    } else {
                        Capsule().strokeBorder(saaa.borderControl, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
