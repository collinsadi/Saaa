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
        .frame(width: 460, height: invisibleMode ? 520 : 470)
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
