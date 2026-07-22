import AgentBridge
import AppKit
import ClaudeBridge
import Core
import DesignSystem
import Persistence
import SwiftUI

/// Session history: revisit past calls — when, how long, where they were
/// filed, what was written where. Metadata comes from the store; content is
/// decrypted on selection only. Deletion is explicit and confirmed.
@MainActor
final class HistoryPresenter {

    private var window: NSWindow?

    func show() {
        let view = HistoryView().saaaThemed()
        let hosting = NSHostingController(rootView: view)
        let window = self.window ?? NSWindow(contentViewController: hosting)
        window.contentViewController = hosting
        window.title = "Saaa History"
        window.setContentSize(NSSize(width: 860, height: 560))
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        CaptureExclusion.shared.register(window, as: .history)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

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

struct HistoryView: View {
    @Environment(\.saaa) private var saaa
    @State private var model = HistoryModel()
    @State private var pendingDelete: SessionStore.Row?

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: 300)
            Divider().overlay(saaa.borderHairline)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(saaa.surfaceBase)
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
    }

    // MARK: - List

    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    BrandMark(size: 13)
                    Text("Calls")
                        .font(SaaaFont.headline)
                        .foregroundStyle(saaa.textPrimary)
                    Spacer()
                    InvisibleModeBadge(surface: .history)
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.sm)
                if model.rows.isEmpty {
                    emptyState
                }
                ForEach(model.rows) { row in
                    Button {
                        model.select(row)
                    } label: {
                        rowView(row)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.md)
        }
    }

    private func rowView(_ row: SessionStore.Row) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
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
                        .foregroundStyle(saaa.tideText)
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
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(model.selected?.id == row.id ? saaa.surfaceInset : .clear))
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("No calls yet")
                .font(SaaaFont.headline)
                .foregroundStyle(saaa.textPrimary)
            Text("Press ⌥⌘R during a call. Every processed recording lands here.")
                .font(SaaaFont.callout)
                .foregroundStyle(saaa.textSecondary)
        }
        .padding(Space.lg)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let row = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text(model.rows.isEmpty ? "" : "Select a call to revisit it")
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func detailHeader(_ row: SessionStore.Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.startedAt.formatted(date: .complete, time: .shortened))
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Text("\(duration(row.duration)) · audio \(row.audioRetained ? "retained" : "deleted after transcription")")
                    .font(SaaaFont.monoCaption)
                    .foregroundStyle(saaa.textTertiary)
            }
            Spacer()
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

    @ViewBuilder
    private func archiveDetail(_ archive: SessionArchive) -> some View {
        if let judgment = archive.judgment, judgment.isConfident,
           let path = judgment.match.projectPath {
            historyCard("Filed to") {
                Text(URL(filePath: path).lastPathComponent)
                    .font(SaaaFont.bodyEmphasis)
                    .foregroundStyle(saaa.textPrimary)
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
        var detail = "\(Int(judgment.match.confidence * 100))% · \(judgment.callType.replacingOccurrences(of: "_", with: " "))"
        if let agent = judgment.filedBy {
            detail += " · \(AgentID(rawValue: agent)?.displayName ?? agent)"
        }
        return detail
    }
}
