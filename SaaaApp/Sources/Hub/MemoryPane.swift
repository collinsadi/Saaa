import Copilot
import Core
import DesignSystem
import SwiftUI

/// Ask all calls: questions across every session on this Mac, answered
/// from the excerpts the on-device search picks, with sources.
struct MemoryPane: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa
    @State private var question = ""
    @FocusState private var focused: Bool

    private var memory: MemoryEngine { model.memory }

    static let suggestions = [
        "What did I promise people this week?",
        "What objections came up this month?",
        "Which calls talked about pricing?",
        "What's still open with my customers?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(
                "Ask all calls",
                subtitle: "Questions across every call on this Mac. Saaa searches them here and sends only the excerpts that matter to Claude."
            ) {
                if !memory.turns.isEmpty {
                    Button {
                        memory.clear()
                    } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, Space.lg)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if memory.turns.isEmpty {
                            emptyState
                        }
                        ForEach(memory.turns) { turn in
                            turnView(turn).id(turn.id)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, Space.lg)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: memory.turns.last?.answer) { _, _ in
                    if let last = memory.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            askBar
                .padding(.horizontal, 36)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: 820 + 72, alignment: .leading)
        }
        .onAppear { focused = true }
    }

    // MARK: - Turns

    private func turnView(_ turn: MemoryEngine.Turn) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(turn.question)
                .font(.system(size: 15, weight: .semibold))
                .textSelection(.enabled)
            if turn.searching {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching your calls on this Mac…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else if let failure = turn.failure, turn.answer.isEmpty {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                if turn.answer.isEmpty, memory.streamingID == turn.id {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(turn.excerpts.count) excerpts from \(Set(turn.excerpts.map(\.sessionID)).count) calls…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    StreamingText(turn.answer, isStreaming: memory.streamingID == turn.id, font: .system(size: 14))
                        .textSelection(.enabled)
                }
                if memory.streamingID != turn.id, !turn.excerpts.isEmpty {
                    sources(turn)
                }
            }
        }
        .saaaCard()
    }

    private func sources(_ turn: MemoryEngine.Turn) -> some View {
        let cited = MemoryPrompt.citations(in: turn.answer).compactMap { number in
            turn.excerpts.indices.contains(number - 1) ? (number: number, excerpt: turn.excerpts[number - 1]) : nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(
                cited.isEmpty ? "Searched" : "Sources",
                trailing: "\(turn.excerpts.count) excerpts, \(Set(turn.excerpts.map(\.sessionID)).count) calls")
            ForEach(cited, id: \.number) { source in
                sourceRow(number: source.number, excerpt: source.excerpt)
            }
        }
        .padding(.top, Space.xs)
    }

    private func sourceRow(number: Int, excerpt: MemoryExcerpt) -> some View {
        Button {
            model.selectedSessionID = excerpt.sessionID
            model.hubPane = .sessions
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("[\(number)]")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(saaa.tideText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceTitle(excerpt))
                        .font(.system(size: 12, weight: .medium))
                    Text(excerpt.chunk.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this call")
    }

    private func sourceTitle(_ excerpt: MemoryExcerpt) -> String {
        var parts = [excerpt.title, excerpt.startedAt.formatted(date: .abbreviated, time: .omitted)]
        switch excerpt.chunk.kind {
        case .summary: parts.append("summary")
        case .prep: parts.append("prep")
        case .transcript: if let time = excerpt.chunk.callTime { parts.append("at \(CallTime.stamp(time))") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Empty and ask

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if model.sessions.isEmpty {
                Text("Once you've had a few calls, ask about them here: what someone said, what you promised, what keeps coming up.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text("Try one of these")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        ask(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "text.magnifyingglass")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.hasAPIKey)
                }
            }
            if !model.hasAPIKey {
                Text("Ask all calls needs Claude. Connect it in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.emberText)
            }
        }
    }

    private var askBar: some View {
        HStack(spacing: Space.sm) {
            TextField("Ask about your calls…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { ask(question) }
            if memory.isBusy {
                Button("Stop") { memory.cancel() }
                    .buttonStyle(.glass)
            } else {
                Button {
                    ask(question)
                } label: {
                    Label("Ask", systemImage: "arrow.up")
                }
                .buttonStyle(.glassProminent)
                .tint(saaa.tideFill)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.hasAPIKey)
            }
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.sm)
        .frame(height: 44)
        .background(Capsule().fill(saaa.surfaceInset))
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, model.hasAPIKey else { return }
        question = ""
        memory.ask(trimmed)
    }
}
