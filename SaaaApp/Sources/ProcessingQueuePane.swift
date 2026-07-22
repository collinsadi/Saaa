import CallSession
import DesignSystem
import SwiftUI

/// The hub's Queue pane: every stopped or imported call moving through
/// transcribe -> match -> judge -> seal in the background, with a Review
/// action the moment one is ready. Recording is never blocked by this.
struct ProcessingQueuePane: View {
    let controller: CallController

    @Environment(\.saaa) private var saaa

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Text("Processing queue")
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
                if !controller.jobs.isEmpty {
                    Button("Clear finished") { controller.clearFinishedJobs() }
                        .buttonStyle(.plain)
                        .font(SaaaFont.caption)
                        .foregroundStyle(saaa.textTertiary)
                }
            }
            Text("Stopped calls land here and process one at a time in the background. Start the next recording whenever you want; nothing waits on this queue.")
                .font(SaaaFont.callout)
                .foregroundStyle(saaa.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.jobs.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Nothing in the queue")
                        .font(SaaaFont.headline)
                        .foregroundStyle(saaa.textPrimary)
                    Text("Stop a recording or import a file and it appears here.")
                        .font(SaaaFont.callout)
                        .foregroundStyle(saaa.textSecondary)
                }
                .padding(Space.lg)
            } else {
                ScrollView {
                    VStack(spacing: Space.xs) {
                        ForEach(controller.jobs.reversed()) { job in
                            row(job)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
    }

    private func row(_ job: ProcessingJob) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon(job.status))
                .foregroundStyle(iconColor(job.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(job.title)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                    .lineLimit(1)
                Text(job.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
            Spacer()
            statusView(job)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
    }

    @ViewBuilder
    private func statusView(_ job: ProcessingJob) -> some View {
        switch job.status {
        case .waiting:
            Text("waiting").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
        case .running(let detail):
            Text(detail)
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.tideText)
                .lineLimit(1)
        case .ready:
            Button("Review") { controller.openReview(id: job.id) }
                .buttonStyle(.plain)
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(saaa.textOnAccent)
                .padding(.horizontal, Space.md)
                .frame(height: Size.controlMd)
                .background(Capsule().fill(saaa.tideFill))
        case .reviewing:
            Text("in review").engravedLabelStyle().foregroundStyle(saaa.tideText)
        case .done:
            Text("done").engravedLabelStyle().foregroundStyle(saaa.successText)
        case .failed(let message):
            Text(message)
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.dangerText)
                .lineLimit(1)
                .help(message)
        }
    }

    private func icon(_ status: ProcessingJob.Status) -> String {
        switch status {
        case .waiting: "clock"
        case .running: "waveform"
        case .ready: "tray.full"
        case .reviewing: "eye"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func iconColor(_ status: ProcessingJob.Status) -> Color {
        switch status {
        case .failed: saaa.dangerText
        case .ready, .reviewing: saaa.tideText
        case .done: saaa.successText
        case .waiting, .running: saaa.textTertiary
        }
    }
}
