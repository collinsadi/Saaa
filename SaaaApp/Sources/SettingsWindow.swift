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
    /// True when hosted inside the hub window's Settings pane (flexible
    /// height, no window registration of its own).
    var embedded = false

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
    @AppStorage("hubOpacity") private var hubOpacity = 1.0
    @AppStorage("hubFadeWhenInactive") private var hubFadeWhenInactive = false
    @AppStorage(LiveAssistController.enabledKey) private var liveAssistEnabled = false
    @AppStorage(LiveAssistController.autoAnswerKey) private var liveAssistAuto = false
    @AppStorage(LiveAssistController.knowledgeFolderKey) private var liveAssistKB = ""

    var body: some View {
        if embedded {
            form
        } else {
            // Standalone settings scrolls at a fixed, screen-friendly size.
            ScrollView {
                form
            }
            .frame(width: 460, height: 640)
            .background(saaa.surfaceBase)
            .background(WindowRegistrar(surface: .settings))
        }
    }

    private var form: some View {
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
            section("Hub window") {
                labeledRow("Opacity") {
                    HStack(spacing: Space.md) {
                        Slider(value: $hubOpacity, in: HubOpacityPolicy.floor...1.0)
                            .tint(saaa.tideFill)
                            .frame(width: 180)
                        Text("\(Int(hubOpacity * 100))%")
                            .font(SaaaFont.monoBody)
                            .foregroundStyle(saaa.textSecondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                toggleRow(
                    "Fade further when the window is inactive",
                    caption: "Text and cards always stay at full strength; only the base fades. The system Reduce Transparency setting overrides both.",
                    isOn: $hubFadeWhenInactive)
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
            section("Live Assist") {
                toggleRow(
                    "Enable Live Assist (advanced)",
                    caption: "While you record with this armed, the rolling transcript streams continuously to your coding agent so it can suggest answers. That is a real departure from Saaa's local-only default. Everyone on the call should know. Meant for your own support, accessibility, and preparation, not for concealing assistance where you are being evaluated.",
                    isOn: $liveAssistEnabled)
                if liveAssistEnabled {
                    toggleRow(
                        "Auto-answer when a question is detected",
                        caption: "Conservative heuristic with a cooldown. The ⌥⌘A hotkey always works.",
                        isOn: $liveAssistAuto)
                    labeledRow("Knowledge folder") {
                        TextField("~/path/to/docs (optional)", text: $liveAssistKB)
                            .textFieldStyle(.plain)
                            .font(SaaaFont.monoBody)
                            .foregroundStyle(saaa.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 230)
                    }
                    Text("Answers ground themselves by reading this folder with read-only tools. Also requires a Live Assist prompt (Prompts pane in the hub); without one the mode stays off.")
                        .font(SaaaFont.caption)
                        .foregroundStyle(saaa.textTertiary)
                }
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
        .frame(width: 460)
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
