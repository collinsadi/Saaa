import AudioCapture
import CallSession
import Core
import DesignSystem
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// Sessions: searchable list on the left (drop recordings to import),
/// the selected session on the right.
struct SessionsPane: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa
    @State private var query = ""
    @State private var searchResults: [SessionIndexEntry]?
    @State private var dropTargeted = false
    @State private var pickerShown = false

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 330)
            Divider()
            Group {
                if let id = model.selectedSessionID {
                    SessionDetailView(model: model, id: id)
                        .id(id)
                } else {
                    EmptyStateView(
                        symbol: "text.page.badge.magnifyingglass",
                        title: "Pick a session",
                        message: "Summaries, action items, the transcript and everything the copilot said.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(isPresented: $pickerShown, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in MediaImporter.expand(urls) { model.session.importRecording(url) }
            }
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                searchResults = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searchResults = await model.library.search(trimmed)
        }
    }

    // MARK: - List

    private var visible: [SessionIndexEntry] {
        searchResults ?? model.sessions
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions").font(.system(size: 22, weight: .bold))
                Spacer()
                Button {
                    pickerShown = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.glass)
                .help("Import a recording")
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, 30)
            .padding(.bottom, Space.md)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles, transcripts, people", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, Space.md)
            .frame(height: 32)
            .saaaGlass(in: Capsule())
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.sm)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    inFlight
                    if visible.isEmpty {
                        Text(searchResults == nil ? "No sessions yet. Record a call or drop a recording here." : "Nothing matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(Space.lg)
                    }
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        } header: {
                            Text(group.title)
                                .engravedLabelStyle()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.lg)
                                .padding(.top, Space.md)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background.opacity(0.0001))
                        }
                    }
                }
                .padding(.bottom, Space.lg)
            }
        }
        .background(dropTargeted ? saaa.tideFill.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = MediaImporter.expand(urls)
            for url in files { model.session.importRecording(url) }
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder
    private var inFlight: some View {
        let imports = model.session.imports.sorted { $0.value < $1.value }
        if !imports.isEmpty || model.session.importFailure != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(imports, id: \.key) { _, status in
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let failure = model.session.importFailure {
                    HStack(alignment: .top, spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(saaa.dangerText)
                        Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.session.clearFailure() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Space.md)
            .saaaGlass(cornerRadius: Radius.control)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
    }

    private struct DayGroup: Sendable {
        let title: String
        let entries: [SessionIndexEntry]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [SessionIndexEntry]] = [:]
        for entry in visible {
            let title: String
            if calendar.isDateInToday(entry.startedAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(entry.startedAt) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: entry.startedAt, to: .now).day, days < 7 {
                title = entry.startedAt.formatted(.dateTime.weekday(.wide))
            } else {
                title = entry.startedAt.formatted(.dateTime.month(.wide).year())
            }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(entry)
        }
        return order.map { DayGroup(title: $0, entries: buckets[$0] ?? []) }
    }

    private func row(_ entry: SessionIndexEntry) -> some View {
        let selected = model.selectedSessionID == entry.id
        return Button {
            model.selectedSessionID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(entry.startedAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text("\(max(1, Int((entry.duration / 60).rounded()))) min")
                    if let playbook = model.playbooks.playbook(id: entry.playbookID) {
                        Text("·")
                        Image(systemName: playbook.symbol).foregroundStyle(playbook.tint.color)
                    }
                    if model.session.summarizing[entry.id] != nil {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if !entry.tldr.isEmpty {
                    Text(entry.tldr)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? saaa.tideFill.opacity(0.16) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.sm)
        .contextMenu {
            Button("Delete…", role: .destructive) { model.delete(entry.id) }
        }
    }
}
