import CallSession
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// The Sessions pane: Import and Queue merged (UI-PLAN §4.3). Drop zone and
/// context fields on top, ONE unified activity list below — staged imports
/// render as queued rows and hand off to the background pipeline, whose jobs
/// render in the same list. Nothing here blocks the next recording.
struct SessionsPane: View {
    let controller: CallController
    let queue: ImportQueueModel

    @Environment(\.saaa) private var saaa
    @State private var pickerPresented = false
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            PaneColumn {
                VStack(alignment: .leading, spacing: Space.lg) {
                    PaneHeader(
                        title: "Sessions",
                        subtitle: "Calls and imports, processed on this Mac.",
                        help: "Stopped calls and imported recordings run through the same pipeline: transcribed on this Mac, matched, reviewed, and sealed. Nothing here blocks your next recording. Only import recordings everyone consented to."
                    ) {
                        if hasFinished {
                            Button("Clear finished") {
                                queue.clearFinished()
                                controller.clearFinishedJobs()
                            }
                            .buttonStyle(.plain)
                            .font(SaaaFont.body)
                            .foregroundStyle(saaa.tideText)
                        }
                    }
                    contextFields
                    dropZone
                    activityList
                }
                .padding(Space.xxl)
            }
        }
        .fileImporter(
            isPresented: $pickerPresented,
            allowedContentTypes: [.audio, .movie, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                queue.add(urls, controller: controller)
            }
        }
    }

    /// Staged imports shown here: waiting (queued) and failed-before-job
    /// rows. Processing and done imports are represented by their pipeline
    /// job so a file never appears twice.
    private var stagedItems: [ImportQueueModel.Item] {
        queue.items.filter { item in
            switch item.status {
            case .waiting, .failed: true
            case .processing, .done: false
            }
        }
    }

    private var hasFinished: Bool {
        controller.jobs.contains { job in
            switch job.status {
            case .done, .failed: true
            default: false
            }
        } || queue.items.contains { item in
            switch item.status {
            case .done, .failed: true
            default: false
            }
        }
    }

    private var contextFields: some View {
        HStack(spacing: Space.md) {
            field("Context title (optional)", text: Binding(
                get: { queue.context.title },
                set: { queue.context.title = $0 }))
            field("Attendees, comma-separated (optional)", text: Binding(
                get: { queue.context.attendees },
                set: { queue.context.attendees = $0 }))
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(SaaaFont.body)
            .foregroundStyle(saaa.textPrimary)
            .padding(.horizontal, Space.md)
            .frame(height: Size.controlLg)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceInset))
    }

    private var dropZone: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(dropTargeted ? saaa.tideText : saaa.textTertiary)
            Text("Drop audio or video here")
                .font(SaaaFont.bodyEmphasis)
                .foregroundStyle(saaa.textPrimary)
            Button("Browse…") { pickerPresented = true }
                .buttonStyle(.plain)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.tideText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(dropTargeted ? saaa.surfaceInset : saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(
                    dropTargeted ? saaa.tideFill : saaa.borderHairline,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls, controller: controller)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Unified activity list

    @ViewBuilder
    private var activityList: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Activity").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
            if stagedItems.isEmpty, controller.jobs.isEmpty {
                PaneEmptyState(
                    headline: "Nothing in flight",
                    guidance: "Stop a recording or drop a file and it lands here.",
                    hotkey: "⌥⌘R")
            } else {
                VStack(spacing: Space.xs + 2) {
                    ForEach(stagedItems) { item in
                        stagedRow(item)
                    }
                    ForEach(controller.jobs.reversed()) { job in
                        jobRow(job)
                    }
                }
            }
        }
    }

    private func stagedRow(_ item: ImportQueueModel.Item) -> some View {
        row(
            icon: item.isFailed ? "exclamationmark.triangle" : "waveform",
            iconColor: item.isFailed ? saaa.dangerText : saaa.textTertiary,
            title: item.url.lastPathComponent,
            detail: "imported"
        ) {
            switch item.status {
            case .failed(let message):
                StatusChip(text: "failed", color: saaa.dangerText)
                    .help(message)
            default:
                StatusChip(text: "queued", color: saaa.textTertiary)
            }
        }
    }

    private func jobRow(_ job: ProcessingJob) -> some View {
        row(
            icon: jobIcon(job.status),
            iconColor: jobIconColor(job.status),
            title: job.title,
            detail: job.startedAt.formatted(date: .abbreviated, time: .shortened)
        ) {
            jobStatusView(job)
        }
    }

    private func row(
        icon: String, iconColor: Color, title: String, detail: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
    }

    @ViewBuilder
    private func jobStatusView(_ job: ProcessingJob) -> some View {
        switch job.status {
        case .waiting:
            StatusChip(text: "waiting", color: saaa.textTertiary)
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
            StatusChip(text: "in review", color: saaa.tideText)
        case .done:
            StatusChip(text: "done", color: saaa.successText)
        case .failed(let message):
            StatusChip(text: "failed", color: saaa.dangerText)
                .help(message)
        }
    }

    private func jobIcon(_ status: ProcessingJob.Status) -> String {
        switch status {
        case .waiting: "clock"
        case .running: "waveform"
        case .ready: "tray.full"
        case .reviewing: "eye"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func jobIconColor(_ status: ProcessingJob.Status) -> Color {
        switch status {
        case .failed: saaa.dangerText
        case .ready, .reviewing: saaa.tideText
        case .done: saaa.successText
        case .waiting, .running: saaa.textTertiary
        }
    }
}

private extension ImportQueueModel.Item {
    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}
