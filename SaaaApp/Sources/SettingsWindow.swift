import AgentBridge
import CallSession
import Core
import DesignSystem
import Persistence
import SwiftUI

/// Saaa's user preferences — a hub pane only (UI-PLAN §4.5): four tabs on a
/// custom design-system tab strip, leading-aligned at the shared measure.
/// Captions live behind HelpDots per the copy rule. Only rows with working
/// plumbing appear.
struct SaaaSettingsView: View {
    let controller: CallController
    /// Settings ▸ General ▸ "Run setup again".
    var onSetup: () -> Void = {}

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case filing = "Filing"
        case assist = "Assist"
        case privacy = "Privacy"
        var id: String { rawValue }
    }

    @Environment(\.saaa) private var saaa
    @State private var tab: Tab = .general
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
    @AppStorage(CodeAssistModel.enabledKey) private var codeAssistEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(SaaaFont.title2)
                .foregroundStyle(saaa.textPrimary)
                .padding(.bottom, Space.md)
            tabStrip
                .padding(.bottom, Space.lg)
            switch tab {
            case .general: generalTab
            case .filing: filingTab
            case .assist: assistTab
            case .privacy: privacyTab
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
        .onChange(of: autoDeleteAudio, initial: true) { _, enabled in
            controller.retention = RetentionPolicy(autoDeleteAudioAfterTranscription: enabled)
        }
    }

    /// Custom tab strip: Tide underline = wayfinding. Native TabView chrome
    /// can't be token-styled; a sub-sidebar would recreate the double-sidebar
    /// smell.
    private var tabStrip: some View {
        HStack(spacing: Space.xl) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue)
                            .font(SaaaFont.bodyEmphasis)
                            .foregroundStyle(tab == item ? saaa.tideText : saaa.textSecondary)
                        Rectangle()
                            .fill(tab == item ? saaa.tideFill : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) {
            Divider().overlay(saaa.borderHairline)
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var generalTab: some View {
        section("Island") {
            toggleRow("Show the island on this Mac", isOn: $showIsland)
            toggleRow("Reduce live movement (freeze meters)", isOn: $freezeMeters)
        }
        // Kept pending the deferred hubOpacity decision (Phase 0 verdict Q1).
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
                help: "Text and cards always stay at full strength; only the base fades. The system Reduce Transparency setting overrides both.",
                isOn: $hubFadeWhenInactive)
        }
        section("Recording") {
            toggleRow(
                "Delete audio after transcription",
                help: "Recommended. The transcript is kept, encrypted; the raw recording is not.",
                isOn: $autoDeleteAudio)
            labeledRow("Record hotkey") {
                Text("⌥⌘R")
                    .font(SaaaFont.monoBody)
                    .foregroundStyle(saaa.textSecondary)
                    .padding(.horizontal, Space.sm)
                    .frame(height: Size.controlSm)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm).fill(saaa.surfaceInset))
            }
        }
        section("Setup", divider: false) {
            labeledRow("Permissions and first-run checks") {
                Button("Run setup again…") { onSetup() }
                    .buttonStyle(.plain)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.tideText)
            }
        }
    }

    @ViewBuilder
    private var filingTab: some View {
        labeledRow("Preferred agent", help: "Auto sends each call to the agent that knows the matched project; the other installed agent is the fallback.") {
            Picker("", selection: $filingAgent) {
                Text("Auto").tag("auto")
                Text("Claude Code").tag(AgentID.claudeCode.rawValue)
                Text("Codex").tag(AgentID.codex.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        labeledRow("Model") {
            Picker("", selection: $filingIntent) {
                Text("Fast").tag("fast")
                Text("Default").tag("default")
                Text("Best").tag("best")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        labeledRow("Exact model") {
            TextField("optional override", text: $filingExactModel)
                .textFieldStyle(.plain)
                .font(SaaaFont.monoBody)
                .foregroundStyle(saaa.textPrimary)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, Space.sm)
                .frame(width: 230, height: Size.controlMd)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(saaa.surfaceInset))
        }
        labeledRow("Filing memory", help: "Learned meeting links and call similarity, sealed on this Mac. Confirmed write-backs teach it.") {
            Button("Clear") { controller.clearFilingMemory() }
                .buttonStyle(.plain)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.dangerText)
        }
    }

    @ViewBuilder
    private var assistTab: some View {
        section("Live Assist") {
            toggleRow(
                "Enable Live Assist (advanced)",
                help: "While you record with this armed, the rolling transcript streams continuously to your coding agent so it can suggest answers. That is a real departure from Saaa's local-only default. Everyone on the call should know. Meant for your own support, accessibility, and preparation, not for concealing assistance where you are being evaluated.",
                isOn: $liveAssistEnabled)
            if liveAssistEnabled {
                toggleRow(
                    "Auto-answer when a question is detected",
                    help: "Conservative heuristic with a cooldown. The ⌥⌘A hotkey always works.",
                    isOn: $liveAssistAuto)
                labeledRow("Knowledge folder", help: "Answers ground themselves by reading this folder with read-only tools. Also requires a Live Assist prompt (Prompts pane); without one the mode stays off.") {
                    TextField("~/path/to/docs (optional)", text: $liveAssistKB)
                        .textFieldStyle(.plain)
                        .font(SaaaFont.monoBody)
                        .foregroundStyle(saaa.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, Space.sm)
                        .frame(width: 230, height: Size.controlMd)
                        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(saaa.surfaceInset))
                }
            }
        }
        section("Code Assist", divider: false) {
            toggleRow(
                "Enable Code Assist (advanced)",
                help: "⇧⌥⌘C captures a screen region YOU select with the system crosshair. The screenshot is read on this Mac and deleted; only its text goes to your agent. Screen content is sensitive, so this stays off until you turn it on. For your own development and practice, not for concealing help in evaluated settings.",
                isOn: $codeAssistEnabled)
        }
    }

    @ViewBuilder
    private var privacyTab: some View {
        toggleRow(
            "Invisible Mode",
            help: "Saaa stays visible to you but is left out of screen recordings and shared screens. It cannot hide from a camera pointed at the display.",
            isOn: $invisibleMode)
        if invisibleMode {
            labeledRow("Hide") {
                Picker("", selection: $invisibleScope) {
                    Text("All windows").tag(InvisibleModeScope.allWindows.rawValue)
                    Text("Call content only").tag(InvisibleModeScope.callContent.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Rows

    private func section(
        _ title: String, divider: Bool = true, @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .engravedLabelStyle()
                .foregroundStyle(saaa.textTertiary)
                .padding(.bottom, Space.xs)
            rows()
            if divider {
                Divider().overlay(saaa.borderHairline)
            }
        }
        .padding(.bottom, Space.lg)
    }

    private func labeledRow(
        _ label: String, help: String? = nil, @ViewBuilder control: () -> some View
    ) -> some View {
        HStack {
            HStack(spacing: Space.sm) {
                Text(label)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                if let help {
                    HelpDot(help)
                }
            }
            Spacer()
            control()
        }
        .padding(.vertical, Space.sm)
    }

    private func toggleRow(
        _ label: String, help: String? = nil, isOn: Binding<Bool>
    ) -> some View {
        HStack {
            HStack(spacing: Space.sm) {
                Text(label)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                if let help {
                    HelpDot(help)
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
