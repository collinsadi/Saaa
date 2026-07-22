import AgentBridge
import AppKit
import DesignSystem
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// Export options sheet (issue #4): renders a sealed session into a
/// shareable HTML or Markdown artifact, with optional agent diarization
/// and a local redaction pass. Diarization failures never block the
/// export — it falls back plain and says so.
struct ExportSheet: View {
    let archive: SessionArchive
    let defaultTitle: String
    let onClose: () -> Void

    @Environment(\.saaa) private var saaa
    @State private var format: ExportFormat = .html
    @State private var includeContext = true
    @State private var diarize = false
    @State private var redactContent = false
    @State private var busy = false
    @State private var note: String?

    private enum ExportFormat: String, CaseIterable {
        case html, markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Export this call")
                .font(SaaaFont.title2)
                .foregroundStyle(saaa.textPrimary)
            Text("Exports are made to leave this Mac. What is included is exactly what you choose below; the raw audio never is.")
                .font(SaaaFont.callout)
                .foregroundStyle(saaa.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Format")
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
                Picker("", selection: $format) {
                    Text("HTML").tag(ExportFormat.html)
                    Text("Markdown").tag(ExportFormat.markdown)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            optionRow(
                "Include summary and extracted context",
                caption: archive.judgment == nil
                    ? "This call has no agent judgment; only the transcript exports."
                    : "Call type, filing, and every extracted card.",
                isOn: $includeContext)
                .disabled(archive.judgment == nil)
            optionRow(
                "Split and name speakers (diarization)",
                caption: "Sends this transcript's text to your coding agent to split and name the other side. Your own segments stay locked. If it is uncertain, the export proceeds without it.",
                isOn: $diarize)
            optionRow(
                "Redact emails, numbers, and amounts",
                caption: "Local and deterministic. It cannot catch names or secrets in plain words; review before sharing.",
                isOn: $redactContent)

            if let note {
                Text(note)
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { onClose() }
                    .buttonStyle(.plain)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    export()
                } label: {
                    Text(busy ? "Working…" : "Export…")
                        .font(SaaaFont.bodyEmphasis)
                        .foregroundStyle(saaa.textOnAccent)
                        .padding(.horizontal, Space.lg)
                        .frame(height: Size.controlLg)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.tideFill))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 480)
        .background(saaa.surfaceBase)
    }

    private func optionRow(
        _ label: String, caption: String, isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(label)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                Text(caption)
                    .font(SaaaFont.caption)
                    .foregroundStyle(saaa.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(saaa.tideFill)
        }
    }

    // MARK: - Export flow

    private func export() {
        busy = true
        note = nil
        Task { @MainActor in
            var exported = archive
            var fallback: String?
            if diarize {
                if let labeled = await DiarizationService().diarize(
                    transcript: archive.transcript,
                    attendees: archive.calendar?.attendees ?? []) {
                    exported.transcript = labeled
                } else {
                    fallback = "Diarization was not confident enough; exporting without speaker names."
                }
            }
            let options = ExportOptions(
                includeContext: includeContext && archive.judgment != nil,
                redact: redactContent)
            let content = switch format {
            case .html:
                TranscriptExporter.html(archive: exported, title: defaultTitle, options: options)
            case .markdown:
                TranscriptExporter.markdown(archive: exported, title: defaultTitle, options: options)
            }
            busy = false
            note = fallback

            let panel = NSSavePanel()
            panel.allowedContentTypes = format == .html
                ? [.html]
                : [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(defaultTitle).\(format == .html ? "html" : "md")"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                if fallback == nil { onClose() }
            } catch {
                note = "Could not write the file: \(error.localizedDescription)"
            }
        }
    }
}
