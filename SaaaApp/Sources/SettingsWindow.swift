import AgentBridge
import CallSession
import Core
import DesignSystem
import Persistence
import SwiftUI

/// Saaa's user preferences (Figma H · Settings). Only rows with working
/// plumbing appear; consent-disclosure and fullscreen behaviors land with
/// the resilience phase.
struct SaaaSettingsView: View {
    let controller: CallController

    @Environment(\.saaa) private var saaa
    @AppStorage("showIsland") private var showIsland = true
    @AppStorage("freezeMeters") private var freezeMeters = false
    @AppStorage("autoDeleteAudio") private var autoDeleteAudio = true
    @AppStorage(CaptureExclusion.enabledKey) private var invisibleMode = false
    @AppStorage(CaptureExclusion.scopeKey) private var invisibleScope =
        InvisibleModeScope.allWindows.rawValue
    @AppStorage(FilingPreferences.agentKey) private var filingAgent = "auto"
    @AppStorage(FilingPreferences.intentKey) private var filingIntent = "default"
    @AppStorage(FilingPreferences.exactModelKey) private var filingExactModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                BrandMark(size: 16)
                Text("Saaa")
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
            }
            .padding(.bottom, Space.xl)
            section("Island") {
                toggleRow("Show the island on this Mac", isOn: $showIsland)
                toggleRow("Reduce live movement (freeze meters)", isOn: $freezeMeters)
            }
            section("Recording") {
                toggleRow(
                    "Delete audio after transcription",
                    caption: "Recommended. The transcript is kept, encrypted; the raw recording is not.",
                    isOn: $autoDeleteAudio)
                HStack {
                    Text("Record hotkey")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.textPrimary)
                    Spacer()
                    Text("⌥⌘R")
                        .font(SaaaFont.monoBody)
                        .foregroundStyle(saaa.textSecondary)
                        .padding(.horizontal, Space.sm)
                        .frame(height: Size.controlSm)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm).fill(saaa.surfaceInset))
                }
                .padding(.vertical, Space.sm)
            }
            section("Filing") {
                labeledRow("Preferred agent") {
                    Picker("", selection: $filingAgent) {
                        Text("Auto").tag("auto")
                        Text("Claude Code").tag(AgentID.claudeCode.rawValue)
                        Text("Codex").tag(AgentID.codex.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
                Text("Auto sends each call to the agent that knows the matched project; the other installed agent is the fallback.")
                    .font(SaaaFont.caption)
                    .foregroundStyle(saaa.textTertiary)
                labeledRow("Model") {
                    Picker("", selection: $filingIntent) {
                        Text("Fast").tag("fast")
                        Text("Default").tag("default")
                        Text("Best").tag("best")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
                labeledRow("Exact model") {
                    TextField("optional override", text: $filingExactModel)
                        .textFieldStyle(.plain)
                        .font(SaaaFont.monoBody)
                        .foregroundStyle(saaa.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 230)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Filing memory")
                            .font(SaaaFont.body)
                            .foregroundStyle(saaa.textPrimary)
                        Text("Learned meeting links and call similarity, sealed on this Mac. Confirmed write-backs teach it.")
                            .font(SaaaFont.caption)
                            .foregroundStyle(saaa.textTertiary)
                    }
                    Spacer()
                    Button("Clear") { controller.clearFilingMemory() }
                        .buttonStyle(.plain)
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.dangerText)
                }
                .padding(.vertical, Space.sm)
            }
            section("Privacy") {
                toggleRow(
                    "Invisible Mode",
                    caption: "Saaa stays visible to you but is left out of screen recordings and shared screens. It cannot hide from a camera pointed at the display.",
                    isOn: $invisibleMode)
                if invisibleMode {
                    HStack {
                        Text("Hide")
                            .font(SaaaFont.body)
                            .foregroundStyle(saaa.textPrimary)
                        Spacer()
                        Picker("", selection: $invisibleScope) {
                            Text("All windows").tag(InvisibleModeScope.allWindows.rawValue)
                            Text("Call content only").tag(InvisibleModeScope.callContent.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230)
                    }
                    .padding(.vertical, Space.sm)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
        .frame(width: 460, height: invisibleMode ? 760 : 710)
        .background(saaa.surfaceBase)
        .background(WindowRegistrar(surface: .settings))
        .onChange(of: autoDeleteAudio, initial: true) { _, enabled in
            controller.retention = RetentionPolicy(autoDeleteAudioAfterTranscription: enabled)
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .engravedLabelStyle()
                .foregroundStyle(saaa.textTertiary)
                .padding(.bottom, Space.xs)
            rows()
            Divider().overlay(saaa.borderHairline)
        }
        .padding(.bottom, Space.lg)
    }

    private func labeledRow(
        _ label: String, @ViewBuilder control: () -> some View
    ) -> some View {
        HStack {
            Text(label)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textPrimary)
            Spacer()
            control()
        }
        .padding(.vertical, Space.sm)
    }

    private func toggleRow(
        _ label: String, caption: String? = nil, isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(label)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                if let caption {
                    Text(caption)
                        .font(SaaaFont.caption)
                        .foregroundStyle(saaa.textTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(saaa.tideFill)
        }
        .padding(.vertical, Space.sm)
    }
}
