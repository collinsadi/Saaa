import AgentBridge
import AppKit
import ClaudeBridge
import Core
import DesignSystem
import Persistence
import SwiftUI

/// Session history as a hub pane (UI-PLAN §4.4): the call list IS the pane
/// content; selecting a row pushes the detail full-pane with a back
/// affordance (and Esc). No second sidebar, no standalone window — ⌘Y opens
/// the hub on this pane. Metadata comes from the store; content is decrypted
/// on selection only. Deletion is explicit and confirmed.
@MainActor
@Observable
final class HistoryModel {
    var rows: [SessionStore.Row] = []
    var selected: SessionStore.Row?
    var selectedArchive: SessionArchive?
    var loadError: String?

    private var store: SessionStore?
    private let encryption = try? EncryptionService()

    func reload() {
        Task {
            do {
                if store == nil { store = try SessionStore() }
                rows = try await store?.all() ?? []
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    func select(_ row: SessionStore.Row) {
        selected = row
        selectedArchive = nil
        loadError = nil
        guard let encryption else {
            loadError = "Encryption key unavailable"
            return
        }
        let url = URL(filePath: row.directoryPath).appendingPathComponent("session.enc")
        do {
            selectedArchive = try encryption.decrypt(SessionArchive.self, from: url)
        } catch {
            loadError = "This session's archive is missing or unreadable."
        }
    }

    func deselect() {
        selected = nil
        selectedArchive = nil
        loadError = nil
    }

    func delete(_ row: SessionStore.Row) {
        Task {
            try? await store?.delete(id: row.id)
            try? FileManager.default.removeItem(at: URL(filePath: row.directoryPath))
            if selected?.id == row.id {
                selected = nil
                selectedArchive = nil
            }
            reload()
        }
    }
}

struct HistoryPane: View {
    @Environment(\.saaa) private var saaa
    @State private var model = HistoryModel()
    @State private var pendingDelete: SessionStore.Row?
    @State private var exportShown = false

    var body: some View {
        Group {
            if model.selected != nil {
                detail
            } else {
                list
            }
        }
        .onAppear { model.reload() }
        .confirmationDialog(
            "Delete this call?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete call and its sealed transcript", role: .destructive) {
                if let row = pendingDelete { model.delete(row) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Anything already written into a project repo stays there; only Saaa's sealed record is removed.")
        }
        .sheet(isPresented: $exportShown) {
            if let archive = model.selectedArchive, let row = model.selected {
                ExportSheet(
                    archive: archive,
                    defaultTitle: archive.calendar?.title
                        ?? "Call \(row.startedAt.formatted(date: .abbreviated, time: .shortened))",
                    onClose: { exportShown = false })
                .saaaThemed()
            }
        }
    }

    // MARK: - List (the pane content — full-width rows, no sidebar styling)

    private var list: some View {
        ScrollView {
            PaneColumn {
                VStack(alignment: .leading, spacing: Space.lg) {
                    PaneHeader(
                        title: "Calls",
                        subtitle: "Every reviewed call, sealed on this Mac.")
                    if model.rows.isEmpty {
                        PaneEmptyState(
                            headline: "No calls yet",
                            guidance: "Record a call and it lands here.",
                            hotkey: "⌥⌘R")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.rows) { row in
                                listRow(row)
                            }
                        }
                    }
                }
                .padding(Space.xxl)
            }
        }
    }

    private func listRow(_ row: SessionStore.Row) -> some View {
        Button {
            model.select(row)
        } label: {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(SaaaFont.bodyEmphasis)
                        .foregroundStyle(saaa.textPrimary)
                    Spacer()
                    Text(duration(row.duration))
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.textTertiary)
                }
                HStack(spacing: Space.sm) {
                    if let project = row.projectPath {
                        Text(URL(filePath: project).lastPathComponent)
                            .font(SaaaFont.caption)
                            .foregroundStyle(saaa.textSecondary)
                    } else {
                        Text("unfiled")
                            .font(SaaaFont.caption)
                            .foregroundStyle(saaa.textTertiary)
                    }
                    if let type = row.callType {
                        Text(type.replacingOccurrences(of: "_", with: " "))
                            .font(SaaaFont.caption)
                            .foregroundStyle(saaa.textTertiary)
                    }
                }
            }
            .padding(.vertical, Space.sm + 2)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Divider().overlay(saaa.borderHairline.opacity(0.6))
        }
    }

    // MARK: - Detail (pushed full-pane; back or Esc pops)

    @ViewBuilder
    private var detail: some View {
        if let row = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    detailToolbar
                    detailHeader(row)
                    if let error = model.loadError {
                        Text(error)
                            .font(SaaaFont.body)
                            .foregroundStyle(saaa.dangerText)
                    }
                    if let archive = model.selectedArchive {
                        archiveDetail(archive)
                    }
                }
                .padding(Space.xxl)
                .frame(maxWidth: Size.transcriptColumnMax, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onExitCommand { pop() }
        }
    }

    private func pop() {
        withAnimation(Motion.standard) { model.deselect() }
    }

    private var detailToolbar: some View {
        HStack(spacing: Space.md) {
            Button {
                pop()
            } label: {
                Text("‹ Calls")
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.tideText)
            }
            .buttonStyle(.plain)
            Spacer()
            if model.selectedArchive != nil {
                Button {
                    exportShown = true
                } label: {
                    Text("Export…")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.tideText)
                }
                .buttonStyle(.plain)
            }
            if let row = model.selected {
                Button {
                    pendingDelete = row
                } label: {
                    Text("Delete…")
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.dangerText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detailHeader(_ row: SessionStore.Row) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(row.startedAt.formatted(date: .complete, time: .shortened))
                .font(SaaaFont.title2)
                .foregroundStyle(saaa.textPrimary)
            Text("\(duration(row.duration)) · audio \(row.audioRetained ? "retained" : "deleted after transcription")")
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.textTertiary)
        }
    }

    @ViewBuilder
    private func archiveDetail(_ archive: SessionArchive) -> some View {
        if let judgment = archive.judgment, judgment.isConfident,
           let path = judgment.match.projectPath {
            historyCard("Filed to") {
                Text(URL(filePath: path).lastPathComponent)
                    .font(SaaaFont.bodyEmphasis)
                    .foregroundStyle(saaa.textPrimary)
                ConfidenceRow(confidence: judgment.match.confidence)
                Text(filedToDetail(judgment))
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
        }
        if !archive.notes.isEmpty {
            historyCard("Written where") {
                ForEach(Array(archive.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(SaaaFont.monoCaption)
                        .foregroundStyle(saaa.textSecondary)
                        .lineLimit(3)
                }
            }
        }
        if let calendar = archive.calendar {
            historyCard("Calendar") {
                Text(calendar.title)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textPrimary)
                if !calendar.attendees.isEmpty {
                    Text(calendar.attendees.joined(separator: ", "))
                        .font(SaaaFont.caption)
                        .foregroundStyle(saaa.textTertiary)
                }
            }
        }
        if let thread = archive.assistThread, !thread.isEmpty {
            historyCard("Live Assist") {
                ForEach(Array(thread.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(spacing: Space.sm) {
                            Text(entry.role == "ask" ? "You asked" : (entry.mode ?? "Assist"))
                                .font(SaaaFont.monoCaption)
                                .foregroundStyle(
                                    entry.role == "ask" ? saaa.textTertiary : saaa.textSecondary)
                            Text(entry.at.formatted(date: .omitted, time: .shortened))
                                .font(SaaaFont.monoCaption)
                                .foregroundStyle(saaa.textTertiary)
                        }
                        if entry.role != "failed" {
                            Text(entry.text)
                                .font(SaaaFont.body)
                                .foregroundStyle(
                                    entry.role == "ask" ? saaa.textSecondary : saaa.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        historyCard("Transcript") {
            ForEach(Array(archive.transcript.segments.enumerated()), id: \.offset) { _, segment in
                HStack(alignment: .top, spacing: Space.sm) {
                    Text(segment.speaker == .me ? "Me" : "Them")
                        .engravedLabelStyle()
                        .foregroundStyle(
                            segment.speaker == .me ? saaa.tideText : saaa.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                    Text(segment.text)
                        .font(SaaaFont.body)
                        .foregroundStyle(saaa.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func historyCard(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).engravedLabelStyle().foregroundStyle(saaa.textTertiary)
            content()
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(saaa.borderHairline, lineWidth: 1))
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    private func filedToDetail(_ judgment: CallJudgment) -> String {
        var detail = judgment.callType.replacingOccurrences(of: "_", with: " ")
        if let agent = judgment.filedBy {
            detail += " · \(AgentID(rawValue: agent)?.displayName ?? agent)"
        }
        return detail
    }
}
