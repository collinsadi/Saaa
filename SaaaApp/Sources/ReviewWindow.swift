import AppKit
import CallSession
import ClaudeBridge
import Core
import Extraction
import SwiftUI

/// The MVP review-and-confirm surface: transcript, project-match card, and
/// the extracted-context checklist whose approval gates every repo write.
/// (The token-driven design-system window replaces this in Phase 9.)
@MainActor
final class ReviewWindowPresenter {

    private var window: NSWindow?

    func show(controller: CallController, transcript: Transcript) {
        let view = ReviewView(
            controller: controller,
            transcript: transcript,
            onClose: { [weak self] in
                self?.window?.close()
                self?.window = nil
                controller.closeReview()
            })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Saaa — Review"
        window.setContentSize(NSSize(width: 620, height: 720))
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ReviewView: View {
    let controller: CallController
    let transcript: Transcript
    let onClose: @MainActor () -> Void

    @State private var approved: Set<Int> = []
    @State private var outcomes: [WriteOutcome]?
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let judgment = controller.lastJudgment {
                matchCard(judgment)
                if !judgment.extracted.isEmpty {
                    extractedList(judgment)
                }
            } else {
                Label("Unfiled — no project judgment for this call", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }
            Divider()
            transcriptSection
            footer
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            approved = Set(controller.lastJudgment.map { Array($0.extracted.indices) } ?? [])
        }
    }

    // MARK: - Sections

    private func matchCard(_ judgment: CallJudgment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = judgment.match.projectPath {
                Label {
                    Text("\(URL(filePath: path).lastPathComponent)  ·  \(Int(judgment.match.confidence * 100))% · \(judgment.callType)")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "folder.fill.badge.gearshape")
                }
                Text(path).font(.caption).foregroundStyle(.secondary)
            } else {
                Label("No confident project match — nothing will be written", systemImage: "tray")
                    .fontWeight(.semibold)
            }
            Text(judgment.match.reasoning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }

    private func extractedList(_ judgment: CallJudgment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extracted context — approve what gets written")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(judgment.extracted.enumerated()), id: \.offset) { index, item in
                        Toggle(isOn: binding(for: index)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.title)  ·  \(item.kind.replacingOccurrences(of: "_", with: " "))")
                                    .fontWeight(.medium)
                                Text(item.body)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .disabled(outcomes != nil)
                    }
                }
            }
            .frame(maxHeight: 220)

            if let outcomes {
                outcomeList(outcomes)
            } else if judgment.match.projectPath != nil {
                Button("Write \(approved.count) item\(approved.count == 1 ? "" : "s") to project") {
                    outcomes = controller.applyWriteBack(approvedItems: approved.sorted())
                }
                .disabled(approved.isEmpty)
            }
        }
    }

    private func outcomeList(_ outcomes: [WriteOutcome]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                switch outcome {
                case .applied(let file):
                    Label(file, systemImage: "checkmark.circle.fill")
                case .conflict(let file, let diff):
                    VStack(alignment: .leading, spacing: 2) {
                        Label("\(file) changed since review — not written", systemImage: "exclamationmark.triangle.fill")
                        Text(diff).font(.caption.monospaced()).lineLimit(6)
                    }
                case .failed(let file, let reason):
                    Label("\(file): \(reason)", systemImage: "xmark.circle.fill")
                }
            }
        }
        .font(.callout)
    }

    private var transcriptSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if transcript.segments.isEmpty {
                    Text("No recognizable speech in this recording.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text(label(for: segment))
                            .fontWeight(.semibold)
                            .frame(width: 52, alignment: .trailing)
                        Text(segment.text).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(4)
        }
    }

    private var footer: some View {
        HStack {
            if let directory = controller.sessionDirectory {
                Button("Show Files") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }
            Spacer()
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { approved.contains(index) },
            set: { include in
                if include { approved.insert(index) } else { approved.remove(index) }
            })
    }

    private func label(for segment: TranscriptSegment) -> String {
        switch segment.speaker {
        case .me: "Me"
        case .them(let label): label ?? "Them"
        }
    }
}
