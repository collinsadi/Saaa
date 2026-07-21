import AppKit
import CallSession
import ClaudeBridge
import Core
import DesignSystem
import Extraction
import SwiftUI

/// The Review & Edit window (Figma H · Review & Edit, light+dark): attributed
/// transcript on the left, the project-match card and extracted-context cards
/// on the right rail, with the confirmation-gated write-back at the bottom.
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
            .saaaThemed()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Saaa — Review"
        window.setContentSize(NSSize(width: 880, height: 640))
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

    @Environment(\.saaa) private var saaa
    @State private var approved: Set<Int> = []
    @State private var outcomes: [WriteOutcome]?
    @State private var seeded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            transcriptPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            rail
                .frame(width: Size.panelWidth)
                .padding(Space.lg)
        }
        .background(saaa.surfaceBase)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            approved = Set(controller.lastJudgment.map { Array($0.extracted.indices) } ?? [])
        }
    }

    // MARK: - Transcript pane

    private var transcriptPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if transcript.segments.isEmpty {
                    Text("No recognizable speech in this recording.")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.textTertiary)
                }
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(spacing: Space.sm) {
                            Text(timestamp(segment.start))
                                .font(SaaaFont.monoCaption)
                                .foregroundStyle(saaa.textTertiary)
                            Text(speakerLabel(segment))
                                .engravedLabelStyle()
                                .foregroundStyle(
                                    segment.speaker == .me ? saaa.tideText : saaa.textSecondary)
                        }
                        Text(segment.text)
                            .font(SaaaFont.body)
                            .foregroundStyle(saaa.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("\(transcript.segments.count) segments · transcript sealed locally")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
                    .padding(.top, Space.sm)
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Right rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    matchCard
                    if let judgment = controller.lastJudgment {
                        ForEach(Array(judgment.extracted.enumerated()), id: \.offset) { index, item in
                            contextCard(index: index, item: item)
                        }
                    }
                    if let outcomes {
                        outcomeCard(outcomes)
                    }
                }
            }
            footerActions
        }
    }

    private var matchCard: some View {
        card {
            if let judgment = controller.lastJudgment,
               let path = judgment.match.projectPath, judgment.isConfident {
                Text("Proj · Matched").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
                Text(URL(filePath: path).lastPathComponent)
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Text(abbreviatePath(path))
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
                    .lineLimit(1)
                confidenceRow(judgment.match.confidence)
                Text(judgment.match.reasoning)
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
                    .lineLimit(3)
            } else {
                Text("Proj · Unfiled").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
                Text("No confident match")
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                if let judgment = controller.lastJudgment,
                   let path = judgment.match.projectPath {
                    // A low-confidence guess is shown as an FYI only.
                    Text("Closest guess: \(URL(filePath: path).lastPathComponent) at \(Int(judgment.match.confidence * 100))% — below the filing bar")
                        .font(SaaaFont.callout)
                        .foregroundStyle(saaa.textSecondary)
                    confidenceRow(judgment.match.confidence)
                }
                Text("The transcript is kept (sealed); nothing will be written to any repo.")
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
            }
        }
    }

    /// Confidence per the state grammar: numeral + worded tier + segmented
    /// meter — never a bare traffic light.
    private func confidenceRow(_ confidence: Double) -> some View {
        let tier = confidence >= 0.75 ? "high" : confidence >= 0.45 ? "medium" : "low"
        let color = confidence >= 0.75
            ? saaa.confidenceHigh : confidence >= 0.45
            ? saaa.confidenceMedium : saaa.confidenceLow
        return HStack(spacing: Space.sm) {
            Text(String(format: "%.2f", confidence))
                .font(SaaaFont.readoutValue)
                .foregroundStyle(saaa.textPrimary)
            Text(tier).engravedLabelStyle().foregroundStyle(color)
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(index) < confidence * 6 ? color : saaa.surfaceInset)
                        .frame(width: 14, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidence \(Int(confidence * 100)) percent, \(tier)")
    }

    private func contextCard(index: Int, item: CallJudgment.ExtractedItem) -> some View {
        card {
            HStack {
                Text("Ctx · \(item.kind.replacingOccurrences(of: "_", with: " "))")
                    .engravedLabelStyle()
                    .foregroundStyle(saaa.textTertiary)
                Spacer()
                Toggle("", isOn: approvalBinding(for: index))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(outcomes != nil)
                    .accessibilityLabel("Include \(item.title)")
            }
            Text(item.title)
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(saaa.textPrimary)
            Text(item.body)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textSecondary)
                .lineLimit(4)
            if let target = targetFile(for: index) {
                Text("writes to: \(target)")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.tideText)
            }
        }
        .opacity(approved.contains(index) || outcomes != nil ? 1 : 0.55)
    }

    private func outcomeCard(_ outcomes: [WriteOutcome]) -> some View {
        card {
            Text("Write-back").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                switch outcome {
                case .applied(let file):
                    Label(file, systemImage: "checkmark.circle.fill")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.successText)
                case .conflict(let file, let diff):
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Label("\(file) changed since review — not written",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(SaaaFont.body)
                            .foregroundStyle(saaa.dangerText)
                        Text(diff)
                            .font(SaaaFont.monoCaption)
                            .foregroundStyle(saaa.textSecondary)
                            .lineLimit(6)
                    }
                case .failed(let file, let reason):
                    Label("\(file): \(reason)", systemImage: "xmark.circle.fill")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.dangerText)
                }
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: Space.md) {
            if outcomes == nil,
               let judgment = controller.lastJudgment,
               judgment.isConfident,
               !judgment.extracted.isEmpty {
                Button {
                    outcomes = controller.applyWriteBack(approvedItems: approved.sorted())
                } label: {
                    Text("Write back — \(approved.count) item\(approved.count == 1 ? "" : "s")")
                        .font(SaaaFont.bodyEmphasis)
                        .foregroundStyle(saaa.textOnAccent)
                        .padding(.horizontal, Space.lg)
                        .frame(height: Size.controlLg)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.tideFill))
                }
                .buttonStyle(.plain)
                .disabled(approved.isEmpty)
                .opacity(approved.isEmpty ? 0.5 : 1)
            }
            Spacer()
            if let directory = controller.sessionDirectory {
                Button("Show Files") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                .buttonStyle(.plain)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.tideText)
            }
            Button(outcomes == nil ? "Discard call" : "Done") { onClose() }
                .buttonStyle(.plain)
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(outcomes == nil ? saaa.dangerText : saaa.textPrimary)
                .keyboardShortcut(outcomes == nil ? .cancelAction : .defaultAction)
        }
    }

    // MARK: - Helpers

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            content()
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1) // fx/raised
    }

    private func approvalBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { approved.contains(index) },
            set: { include in
                if include { approved.insert(index) } else { approved.remove(index) }
            })
    }

    /// Where the router would write this item (shown on the card).
    private func targetFile(for index: Int) -> String? {
        guard let judgment = controller.lastJudgment else { return nil }
        return WriteBackRouter.plan(judgment: judgment, approvedItems: [index])
            .first?.targetFile
    }

    private func speakerLabel(_ segment: TranscriptSegment) -> String {
        switch segment.speaker {
        case .me: "Me"
        case .them(let label): label ?? "Them"
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
