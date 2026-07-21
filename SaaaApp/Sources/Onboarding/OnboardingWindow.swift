import AppKit
import DesignSystem
import SwiftUI

/// First-run bootstrap window (Figma H · Onboarding): four steps, permission
/// cards with engraved headers and trailing status, Back/Continue.
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
        window.setContentSize(NSSize(width: 560, height: 560))
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
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Step \(model.step + 1) of \(model.stepCount) · \(stepName)")
                .engravedLabelStyle()
                .foregroundStyle(saaa.textTertiary)
            stepBody
            Spacer(minLength: 0)
            footer
        }
        .padding(Space.xxl)
        .frame(width: 560, height: 560)
        .background(saaa.surfaceBase)
        .onAppear { model.refresh() }
    }

    private var stepName: String {
        ["Welcome", "Permissions", "Transcription", "Claude Code"][model.step]
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
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Every call, in context")
                .font(SaaaFont.title1)
                .foregroundStyle(saaa.textPrimary)
            Text("Press ⌥⌘R during a call. Saaa records both sides, transcribes on this Mac, files the conversation into the right project with your own Claude Code, and writes back only what you approve.")
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textSecondary)
            card("Private by design", status: nil) {
                Text("Nothing is uploaded, ever. Audio is deleted the moment its transcript exists; transcripts are encrypted on this Mac. The only outbound traffic is your own Claude Code subscription.")
            }
            card("Consent is yours to give", status: nil) {
                Text("Recording calls is legally sensitive. In many places every participant must consent. Saaa always shows a visible recording indicator — telling people you record is your responsibility.")
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Saaa listens only while you record")
                .font(SaaaFont.title1)
                .foregroundStyle(saaa.textPrimary)
            permissionCard(
                "Microphone", status: model.micStatus,
                body: "Your side of the call.",
                actionTitle: "Grant") { model.requestMicrophone() }
            card("System audio", status: model.systemAudioStatus) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("The other side of the call. macOS requires adding Saaa by hand:")
                    Text("1. Open the Settings pane below\n2. In the LOWER list — “System Audio Recording Only” — click ＋\n3. Choose Applications → Saaa, toggle it on\n4. Come back and Verify")
                        .font(SaaaFont.callout)
                        .foregroundStyle(saaa.textSecondary)
                    HStack(spacing: Space.md) {
                        actionButton("Open Settings") { model.openSystemAudioSettings() }
                        actionButton("Verify") { model.verifySystemAudio() }
                    }
                }
            }
            permissionCard(
                "Calendar", status: model.calendarStatus,
                body: "Reads only the event overlapping a call — a strong hint for filing.",
                actionTitle: "Grant") { model.requestCalendar() }
        }
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Transcription lives on this Mac")
                .font(SaaaFont.title1)
                .foregroundStyle(saaa.textPrimary)
            Text("Saaa uses Whisper (large-v3-turbo) running locally — your audio never leaves the machine. The model is fetched once, checksum-verified, and cached forever.")
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textSecondary)
            permissionCard(
                "Whisper model", status: model.modelStatus,
                body: "ggml-large-v3-turbo + Silero voice-activity model.",
                actionTitle: "Download") { model.downloadModels() }
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Your Claude Code does the filing")
                .font(SaaaFont.title1)
                .foregroundStyle(saaa.textPrimary)
            Text("Saaa asks the claude CLI — under your existing subscription — which project a call belongs to and what context is worth keeping. Saaa manages no API keys.")
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textSecondary)
            permissionCard(
                "claude CLI", status: model.claudeStatus,
                body: "Read-only for matching; repo writes always need your approval.",
                actionTitle: "Check") { model.checkClaude() }
            card("Without it", status: nil) {
                Text("Saaa still records and transcribes — calls simply stay “unfiled” until Claude Code is available.")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.step > 0 {
                Button("Back") { model.step -= 1 }
                    .buttonStyle(.plain)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textSecondary)
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
                Text(model.step < model.stepCount - 1 ? "Continue" : "Start using Saaa")
                    .font(SaaaFont.bodyEmphasis)
                    .foregroundStyle(saaa.textOnAccent)
                    .padding(.horizontal, Space.lg)
                    .frame(height: Size.controlLg)
                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.tideFill))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Pieces

    private func permissionCard(
        _ title: String, status: OnboardingModel.StepStatus,
        body bodyText: String, actionTitle: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        card(title, status: status) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(bodyText)
                if showAction(for: status) {
                    actionButton(actionTitle, action: action)
                }
            }
        }
    }

    private func showAction(for status: OnboardingModel.StepStatus) -> Bool {
        switch status {
        case .granted, .working: false
        default: true
        }
    }

    private func card(
        _ title: String, status: OnboardingModel.StepStatus?,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title).engravedLabelStyle().foregroundStyle(saaa.textTertiary)
                Spacer()
                if let status {
                    statusText(status)
                }
            }
            content()
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textPrimary)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
    }

    @ViewBuilder
    private func statusText(_ status: OnboardingModel.StepStatus) -> some View {
        switch status {
        case .unknown:
            EmptyView()
        case .working(let message):
            Text(message).font(SaaaFont.caption).foregroundStyle(saaa.textTertiary)
        case .granted(let message):
            Text(message).font(SaaaFont.caption).foregroundStyle(saaa.successText)
        case .actionNeeded(let message):
            Text(message)
                .font(SaaaFont.caption)
                .foregroundStyle(saaa.emberText)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    private func actionButton(
        _ title: String, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(saaa.tideText)
                .padding(.horizontal, Space.md)
                .frame(height: Size.controlMd)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(saaa.borderControl, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
