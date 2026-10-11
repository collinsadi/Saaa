import AnthropicKit
import CallSession
import Copilot
import Core
import DesignSystem
import Persistence
import SwiftUI

/// One session as a document: TL;DR, decisions, action items, playbook
/// sections, follow-up email; the transcript; the copilot thread; and
/// "Ask this call" for anything else.
struct SessionDetailView: View {
    @Bindable var model: AppModel
    let id: UUID

    @Environment(\.saaa) private var saaa
    @State private var record: SessionRecord?
    @State private var loadFailed = false
    @State private var tab: Tab = .summary
    @State private var transcriptQuery = ""
    @State private var exportShown = false
    @State private var confirmDelete = false
    @State private var copied = false

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case copilot = "Copilot"
        case ask = "Ask"
        var id: String { rawValue }
    }

    private var entry: SessionIndexEntry? { model.sessions.first { $0.id == id } }

    var body: some View {
        Group {
            if let record {
                document(record)
            } else if loadFailed {
                EmptyStateView(symbol: "lock.slash", title: "Can't open this session", message: "Its sealed archive is missing or unreadable.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entry?.hasSummary) { await load() }
        .sheet(isPresented: $exportShown) {
            if let record {
                ExportSheet(record: record) { exportShown = false }
            }
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete) {
            Button("Delete session", role: .destructive) { model.delete(id) }
        } message: {
            Text("The sealed transcript, summary and notes are removed from this Mac. Files you saved elsewhere stay.")
        }
    }

    private func load() async {
        if let loaded = await model.record(id) {
            record = loaded
        } else {
            loadFailed = true
        }
    }

    private func save(_ updated: SessionRecord) {
        record = updated
        model.update(updated)
    }

    // MARK: - Document

    private func document(_ record: SessionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header(record)
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
                switch tab {
                case .summary: summaryTab(record)
                case .transcript: transcriptTab(record)
                case .copilot: copilotTab(record)
                case .ask: AskThisCall(model: model, record: record, onUpdate: save)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                if let playbook = model.playbooks.playbook(id: record.playbookID) {
                    PlaybookBadge(playbook, compact: true)
                } else {
                    Text(record.playbookName).font(.system(size: 11))
                }
                Text("· \(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(max(1, Int((record.duration / 60).rounded()))) min")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if record.usage.totalCostUSD > 0 {
                    Text("· \(UsageLedger.format(record.usage.totalCostUSD))")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .help("Claude usage for this session")
                }
                Spacer(minLength: Space.sm)
                actions(record)
                    .fixedSize()
            }
            Text(record.displayTitle)
                .font(.system(size: 28, weight: .bold))
                .textSelection(.enabled)
            if !record.context.participants.isEmpty {
                Label(record.context.participants, systemImage: "person.2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            summaryStatus(record)
        }
    }

    private func actions(_ record: SessionRecord) -> some View {
        HStack(spacing: Space.sm) {
            Button {
                Exporting.copyMarkdown(record)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.glass)
            .help("Copy the summary as Markdown")
            Button {
                Exporting.saveToFolder(record)
            } label: {
                Label("Save", systemImage: "folder")
            }
            .buttonStyle(.glass)
            .help("Save Markdown to your notes folder")
            Menu {
                Button("Export…") { exportShown = true }
                if model.hasAPIKey {
                    Button(record.summary == nil ? "Write summary" : "Rewrite summary") {
                        model.session.summarize(record)
                    }
                }
                Button("Show in Finder") {
                    let folder = model.library.sessionsDirectory
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func summaryStatus(_ record: SessionRecord) -> some View {
        if let summary = record.summary {
            if !summary.tldr.isEmpty {
                Text(summary.tldr)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .saaaGlass(cornerRadius: Radius.card, tint: saaa.tideFill.opacity(0.12))
            }
        } else if let status = model.session.summarizing[record.id] {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text(status).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .saaaGlass(cornerRadius: Radius.card)
        } else {
            HStack(spacing: Space.md) {
                Image(systemName: "text.document").foregroundStyle(.secondary)
                Text(model.session.summaryFailures[record.id]
                     ?? (model.hasAPIKey ? "No summary yet." : "Add a Claude API key to write summaries."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.hasAPIKey, !record.transcript.segments.isEmpty {
                    Button("Write summary") { model.session.summarize(record) }
                        .buttonStyle(.glassProminent)
                        .tint(saaa.tideFill)
                }
            }
            .padding(Space.lg)
            .saaaGlass(cornerRadius: Radius.card)
        }
    }

    // MARK: - Summary tab

    @ViewBuilder
    private func summaryTab(_ record: SessionRecord) -> some View {
        if let summary = record.summary {
            VStack(alignment: .leading, spacing: Space.lg) {
                bulletCard("Key points", summary.keyPoints)
                bulletCard("Decisions", summary.decisions)
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("Action items", trailing: "\(summary.actionItems.filter { !$0.done }.count) open")
                        ForEach(summary.actionItems) { item in
                            actionRow(item, record: record)
                        }
                    }
                    .saaaCard()
                }
                bulletCard("Open questions", summary.openQuestions)
                ForEach(summary.sections) { section in
                    bulletCard(section.title, section.bullets)
                }
                if let email = summary.followUpEmail {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack {
                            SectionLabel("Follow-up email")
                            Spacer()
                            Button {
                                Exporting.copy(email)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        Text(email)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .saaaCard()
                }
                Text("Written by \(ModelCatalog.model(id: summary.model)?.shortName ?? summary.model) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } else if let notes = record.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("Notes taken during the call").font(.system(size: 13)).foregroundStyle(.secondary)
                bulletCard("Key points", notes.keyPoints)
                bulletCard("Decisions", notes.decisions)
                bulletCard("Action items", notes.actionItems)
                bulletCard("Open questions", notes.openQuestions)
            }
        } else {
            Text("The summary appears here once it's written.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bulletCard(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionLabel(title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Circle().fill(saaa.tideText).frame(width: 5, height: 5).offset(y: -2)
                        Text(item).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                    }
                }
            }
            .saaaCard()
        }
    }

    private func actionRow(_ item: MeetingSummary.ActionItem, record: SessionRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Button {
                var updated = record
                if let index = updated.summary?.actionItems.firstIndex(where: { $0.id == item.id }) {
                    updated.summary?.actionItems[index].done.toggle()
                    save(updated)
                }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.done ? saaa.successText : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 14))
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .textSelection(.enabled)
                let tags = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
                if !tags.isEmpty {
                    Text(tags.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Transcript tab

    private func transcriptTab(_ record: SessionRecord) -> some View {
        let needle = transcriptQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let segments = record.transcript.segments.filter { needle.isEmpty || $0.text.lowercased().contains(needle) }
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $transcriptQuery).textFieldStyle(.plain)
                Spacer()
                Text("\(record.transcript.segments.count) lines")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, Space.md)
            .frame(height: 32)
            .saaaGlass(in: Capsule())
            if segments.isEmpty {
                Text(record.transcript.segments.isEmpty ? "No speech was transcribed." : "Nothing matches.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: Space.md) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        Text(CallTime.stamp(segment.start))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 48, alignment: .trailing)
                        Text(segment.speaker == .me ? "Me" : "Them")
                            .engravedLabelStyle()
                            .foregroundStyle(segment.speaker == .me ? saaa.tideText : Color.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(segment.text)
                            .font(.system(size: 14))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Copilot tab

    @ViewBuilder
    private func copilotTab(_ record: SessionRecord) -> some View {
        let thread = record.thread.filter { $0.failure == nil && !$0.response.isEmpty }
            .sorted { ($0.isPinned ? 0 : 1, $0.callTime) < ($1.isPinned ? 0 : 1, $1.callTime) }
        if thread.isEmpty {
            Text("The copilot wasn't asked anything in this session.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(thread) { exchange in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.sm) {
                            if exchange.isPinned { Image(systemName: "pin.fill").foregroundStyle(saaa.tideText) }
                            Text(exchange.title).engravedLabelStyle().foregroundStyle(saaa.tideText)
                            Text(CallTime.stamp(exchange.callTime))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        if let prompt = exchange.prompt, exchange.kind != .action {
                            Text("“\(prompt)”").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text(exchange.response)
                            .font(.system(size: 14))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                    .saaaCard()
                }
            }
        }
    }
}

/// "Ask this call": chat with a finished session.
struct AskThisCall: View {
    let model: AppModel
    let record: SessionRecord
    let onUpdate: (SessionRecord) -> Void

    @Environment(\.saaa) private var saaa
    @State private var input = ""
    @State private var streaming: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private let suggestions = [
        "What did we agree on?",
        "What do I owe them, and by when?",
        "What objections or concerns came up?",
        "Draft a short follow-up message.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if record.chat.isEmpty, streaming == nil {
                Text("Ask anything about this conversation.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                FlowRow(spacing: Space.sm) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }
            ForEach(record.chat) { turn in
                bubble(turn.text, mine: turn.role == .user)
            }
            if let streaming {
                bubble(streaming.isEmpty ? "…" : streaming, mine: false, streaming: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.dangerText)
            }
            HStack(spacing: Space.sm) {
                TextField(model.hasAPIKey ? "Ask about this call…" : "Add a Claude API key to ask questions", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { send(input) }
                    .disabled(!model.hasAPIKey || streaming != nil)
                Button {
                    send(input)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(input.isEmpty ? Color.secondary : saaa.tideText)
                .disabled(input.isEmpty || streaming != nil)
            }
            .padding(.horizontal, Space.md)
            .frame(height: 40)
            .saaaGlass(in: Capsule())
        }
        .onDisappear { task?.cancel() }
    }

    private func bubble(_ text: String, mine: Bool, streaming: Bool = false) -> some View {
        HStack {
            if mine { Spacer(minLength: 80) }
            StreamingText(text, isStreaming: streaming, font: .system(size: 14))
                .padding(Space.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(mine ? saaa.tideFill.opacity(0.16) : saaa.surfaceRaised))
                .frame(maxWidth: 560, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 80) }
        }
    }

    private func send(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, streaming == nil else { return }
        input = ""
        error = nil
        streaming = ""
        let history = record.chat
        let playbook = model.playbooks.playbook(id: record.playbookID) ?? .general
        let material = PromptComposer.ChatMaterial(
            title: record.displayTitle, startedAt: record.startedAt, transcript: record.transcript,
            summary: record.summary, notes: record.notes)
        let stream = MeetingChat(service: AnthropicClient.keychain()).ask(
            question, history: history, material: material, playbook: playbook, context: record.context)
        task = Task {
            var answer = ""
            var finished: StreamResult?
            do {
                for try await event in stream {
                    switch event {
                    case .text(let piece):
                        answer += piece
                        streaming = answer
                    case .finished(let result):
                        finished = result
                    case .started:
                        break
                    }
                }
                var updated = record
                updated.chat.append(ChatTurn(role: .user, text: question))
                updated.chat.append(ChatTurn(role: .assistant, text: answer.trimmingCharacters(in: .whitespacesAndNewlines)))
                if let finished { updated.usage.add(UsageRecord(role: .chat, result: finished)) }
                streaming = nil
                onUpdate(updated)
            } catch {
                streaming = nil
                self.error = (error as? AnthropicError)?.userMessage ?? "Couldn't get an answer."
            }
        }
    }
}

/// Wrapping row of chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Export options.
struct ExportSheet: View {
    let record: SessionRecord
    let onClose: () -> Void

    @State private var format: Exporting.Format = .markdown
    @State private var includeTranscript = true
    @State private var includeCopilot = false
    @State private var redact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Export").font(.system(size: 20, weight: .bold))
            Text("Exports leave this Mac. They contain exactly what you pick here, never audio.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Format", selection: $format) {
                ForEach(Exporting.Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Include the transcript", isOn: $includeTranscript)
            Toggle("Include copilot suggestions", isOn: $includeCopilot)
            Toggle("Redact emails, long numbers and amounts", isOn: $redact)
            Text("Redaction is local and pattern-based; it can't catch names or secrets in plain words.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Export…") {
                    Exporting.export(
                        record, format: format,
                        options: .init(includeTranscript: includeTranscript, includeCopilotThread: includeCopilot, redact: redact))
                    onClose()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 440)
    }
}
