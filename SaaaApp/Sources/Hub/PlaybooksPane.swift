import AppKit
import Copilot
import Core
import DesignSystem
import Persistence
import SwiftUI

/// Playbooks: how Saaa helps on each kind of call. A grid of cards; picking
/// one opens its editor in place.
struct PlaybooksPane: View {
    @Bindable var model: AppModel

    @State private var draft: Playbook?
    @State private var draftIsNew = false
    @State private var pendingRemoval: Playbook?

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: Space.lg, alignment: .top)]

    var body: some View {
        content
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { playbook in
                Button(playbook.isBuiltIn ? "Reset" : "Delete", role: .destructive) {
                    remove(playbook)
                }
            } message: { playbook in
                Text(playbook.isBuiltIn
                    ? "Your changes to \(playbook.name) are discarded and the original comes back."
                    : "\(playbook.name) and its knowledge are removed from this Mac.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let binding = Binding($draft) {
            PlaybookEditor(
                draft: binding,
                isNew: draftIsNew,
                hasChanges: hasChanges,
                isDefault: model.playbooks.defaultID == binding.wrappedValue.id,
                isEdited: model.playbooks.isEdited(binding.wrappedValue.id),
                onSave: save,
                onClose: close,
                onDuplicate: { duplicate(binding.wrappedValue) },
                onMakeDefault: { model.setDefaultPlaybook(binding.wrappedValue.id) },
                onRemove: { pendingRemoval = binding.wrappedValue })
            .id(binding.wrappedValue.id)
        } else {
            grid
        }
    }

    private var removalTitle: String {
        guard let playbook = pendingRemoval else { return "" }
        return playbook.isBuiltIn ? "Reset \(playbook.name)?" : "Delete \(playbook.name)?"
    }

    private var hasChanges: Bool {
        guard let draft else { return false }
        if draftIsNew { return true }
        return model.playbooks.playbook(id: draft.id) != draft
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                PaneHeader(
                    "Playbooks",
                    subtitle: "Your role on each kind of call, the quick actions you get, the words to listen for, and what the summary covers."
                ) {
                    Button(action: startNew) {
                        Label("New playbook", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Space.lg) {
                    ForEach(model.playbooks.all) { playbook in
                        Button {
                            open(playbook)
                        } label: {
                            PlaybookCard(
                                playbook: playbook,
                                isDefault: model.playbooks.defaultID == playbook.id,
                                isEdited: model.playbooks.isEdited(playbook.id),
                                inUse: model.session.isLive && model.session.playbook.id == playbook.id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: playbook) }
                    }
                }
                Label(
                    "When a meeting title matches a playbook's calendar words, Saaa suggests that playbook. Otherwise it uses your default.",
                    systemImage: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func menu(for playbook: Playbook) -> some View {
        Button("Edit") { open(playbook) }
        Button("Duplicate") { duplicate(playbook) }
        Button("Make default") { model.setDefaultPlaybook(playbook.id) }
            .disabled(model.playbooks.defaultID == playbook.id)
        if model.session.isLive, model.session.playbook.id != playbook.id {
            Button("Use for this call") { model.session.switchPlaybook(playbook) }
        }
        if model.playbooks.isEdited(playbook.id) {
            Divider()
            Button("Reset to original…", role: .destructive) { pendingRemoval = playbook }
        } else if !playbook.isBuiltIn {
            Divider()
            Button("Delete…", role: .destructive) { pendingRemoval = playbook }
        }
    }

    // MARK: - Actions

    private func open(_ playbook: Playbook) {
        draftIsNew = false
        draft = playbook
    }

    private func startNew() {
        draftIsNew = true
        draft = Playbook(
            id: "custom.\(UUID().uuidString)", name: "", symbol: "sparkles", tint: .violet,
            tagline: "", instructions: "", quickActions: StandardActions.all)
    }

    private func close() {
        draft = nil
        draftIsNew = false
    }

    private func save() {
        guard var playbook = draft else { return }
        playbook.name = playbook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        playbook.tagline = playbook.tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        playbook.instructions = playbook.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        for index in playbook.quickActions.indices {
            playbook.quickActions[index].title = playbook.quickActions[index].title.trimmingCharacters(in: .whitespaces)
            playbook.quickActions[index].instruction = playbook.quickActions[index].instruction
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        model.upsertPlaybook(playbook)
        close()
    }

    private func duplicate(_ playbook: Playbook) {
        let copy = playbook.duplicated()
        model.upsertPlaybook(copy)
        draftIsNew = false
        draft = copy
    }

    private func remove(_ playbook: Playbook) {
        model.removePlaybook(playbook.id)
        if draft?.id == playbook.id {
            close()
        }
        pendingRemoval = nil
    }
}

// MARK: - Card

private struct PlaybookCard: View {
    let playbook: Playbook
    let isDefault: Bool
    let isEdited: Bool
    let inUse: Bool

    @Environment(\.saaa) private var saaa
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top) {
                PlaybookGlyph(symbol: playbook.symbol, tint: playbook.tint, size: 40)
                Spacer()
                HStack(spacing: 6) {
                    if inUse { tag("In use", color: saaa.emberText) }
                    if isDefault { tag("Default", color: saaa.tideText) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(playbook.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(saaa.textPrimary)
                Text(playbook.tagline.isEmpty ? " " : playbook.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: Space.md) {
                stat("bolt.fill", playbook.quickActions.count, "quick actions")
                stat("textformat", playbook.vocabulary.count, "words to listen for")
                stat("doc.text", playbook.knowledge.count, "knowledge files")
                Spacer()
                Text(isEdited ? "Edited" : playbook.isBuiltIn ? "Built-in" : "Yours")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(saaa.textTertiary)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(saaa.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(
                    hovering ? playbook.tint.color.opacity(0.7) : saaa.borderHairline.opacity(0.7),
                    lineWidth: hovering ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the playbook editor")
    }

    private func stat(_ symbol: String, _ value: Int, _ label: String) -> some View {
        Label("\(value)", systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(saaa.textSecondary)
            .help("\(value) \(label)")
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// A playbook's symbol on its tint: the one icon used everywhere.
struct PlaybookGlyph: View {
    let symbol: String
    let tint: PlaybookTint
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(
                colors: [tint.color, tint.color.opacity(0.72)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

// MARK: - Editor

private struct PlaybookEditor: View {
    @Binding var draft: Playbook
    let isNew: Bool
    let hasChanges: Bool
    let isDefault: Bool
    let isEdited: Bool
    let onSave: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onMakeDefault: () -> Void
    let onRemove: () -> Void

    @Environment(\.saaa) private var saaa
    @State private var showSymbols = false
    @State private var importErrors: [String] = []
    @State private var dropTargeted = false
    @State private var confirmDiscard = false

    private static let playbookSymbols = [
        "sparkles", "chart.line.uptrend.xyaxis", "heart.text.square", "person.text.rectangle",
        "building.columns", "person.3", "person.2", "graduationcap", "briefcase", "dollarsign.circle",
        "cart", "megaphone", "lightbulb", "hammer", "wrench.and.screwdriver", "stethoscope",
        "scalemass", "globe", "phone", "bubble.left.and.bubble.right", "doc.text.magnifyingglass",
        "target", "flag", "star", "bolt", "brain.head.profile", "book", "paintpalette",
        "laptopcomputer", "house",
    ]

    private var problems: [String] {
        var list: [String] = []
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list.append("Give the playbook a name.")
        }
        let incomplete = draft.quickActions.contains {
            $0.title.trimmingCharacters(in: .whitespaces).isEmpty
                || $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if incomplete {
            list.append("Each quick action needs a title and an instruction.")
        }
        return list
    }

    private var tokenEstimate: Int { draft.knowledgeCharacters / 4 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                identity
                instructionsSection
                actionsSection
                vocabularySection
                knowledgeSection
                summarySection
                behaviorSection
                coachingSection
                matchingSection
                if !isNew {
                    manageSection
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, Space.lg)
            .padding(.bottom, 40)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaBar(edge: .top) {
            header
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: onClose)
        }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Button {
                if hasChanges, !isNew || !draft.name.isEmpty {
                    confirmDiscard = true
                } else {
                    onClose()
                }
            } label: {
                Label("Playbooks", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            Spacer()
            if let problem = problems.first, hasChanges {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(saaa.dangerText)
            } else if hasChanges, !isNew {
                Text("Unsaved changes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button(isNew ? "Create" : "Save", action: onSave)
                .buttonStyle(.glassProminent)
                .tint(saaa.tideFill)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasChanges || !problems.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.top, 22)
        .padding(.bottom, Space.md)
    }

    // MARK: Identity

    private var identity: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            Button {
                showSymbols = true
            } label: {
                PlaybookGlyph(symbol: draft.symbol, tint: draft.tint, size: 64)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                            .offset(x: 6, y: 6)
                    }
            }
            .buttonStyle(.plain)
            .help("Choose a symbol")
            .accessibilityLabel("Choose a symbol")
            .popover(isPresented: $showSymbols, arrowEdge: .bottom) {
                SymbolGrid(symbols: Self.playbookSymbols, selection: $draft.symbol, tint: draft.tint.color)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Playbook name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold))
                TextField("One line about this kind of call", text: $draft.tagline)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(PlaybookTint.allCases, id: \.self) { tint in
                        Button {
                            draft.tint = tint
                        } label: {
                            Circle()
                                .fill(tint.color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(draft.tint == tint ? 0.8 : 0), lineWidth: 2)
                                        .padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tint.rawValue.capitalized)
                        .accessibilityAddTraits(draft.tint == tint ? .isSelected : [])
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 4)
            }
        }
        .padding(.top, Space.sm)
    }

    // MARK: Sections

    private var instructionsSection: some View {
        EditorSection(
            "How to help",
            caption: "Your role on these calls and what good help looks like, in your words. Saaa follows this for every answer."
        ) {
            TextEditor(text: $draft.instructions)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(Space.sm)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(saaa.surfaceInset))
                .overlay(alignment: .topLeading) {
                    if draft.instructions.isEmpty {
                        Text("For example: I'm an account executive selling to IT leaders. Keep answers short, lead with their problem, and never promise dates.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Space.sm + 5)
                            .padding(.vertical, Space.sm)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var actionsSection: some View {
        EditorSection(
            "Quick actions",
            caption: "One-tap help in the live panel. The first four also answer to ⌘1 to ⌘4."
        ) {
            VStack(spacing: Space.sm) {
                ForEach($draft.quickActions) { $action in
                    let position = draft.quickActions.firstIndex { $0.id == action.id } ?? 0
                    QuickActionRow(
                        action: $action,
                        position: position,
                        count: draft.quickActions.count,
                        onMove: { offset in move(action.id, by: offset) },
                        onDelete: { draft.quickActions.removeAll { $0.id == action.id } })
                }
                HStack(spacing: Space.md) {
                    Button {
                        addAction(QuickAction(
                            id: "custom.\(UUID().uuidString)", title: "", symbol: "sparkles",
                            instruction: "", kind: .custom))
                    } label: {
                        Label("Add action", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    Menu("Add a standard action") {
                        ForEach(StandardActions.all) { standard in
                            Button(standard.title) {
                                var copy = standard
                                copy.id = "\(standard.id).\(UUID().uuidString)"
                                addAction(copy)
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    Spacer()
                }
                .disabled(draft.quickActions.count >= 8)
            }
        }
    }

    private var vocabularySection: some View {
        EditorSection(
            "Words to listen for",
            caption: "Names, products and jargon. Saaa tunes transcription to them and spells them right in answers."
        ) {
            TokenEditor(tokens: $draft.vocabulary, placeholder: "Add words, separated by commas")
        }
    }

    private var knowledgeSection: some View {
        EditorSection(
            "Knowledge",
            caption: "Reference material Saaa can draw on: pricing, FAQs, rubrics, notes. Text is extracted on this Mac and stored encrypted. The files themselves aren't kept."
        ) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(draft.knowledge) { item in
                    HStack(spacing: Space.md) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text("\(item.text.count.formatted()) characters, added \(item.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            draft.knowledge.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(.vertical, 2)
                }
                HStack(spacing: Space.md) {
                    Button {
                        let result = KnowledgeImporter.pick()
                        draft.knowledge.append(contentsOf: result.items)
                        importErrors = result.errors
                    } label: {
                        Label("Add files…", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    Text("or drop them here")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if draft.knowledgeCharacters > 0 {
                        Text("About \(tokenEstimate.formatted()) tokens")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("Sent with each request and cached, so repeat answers cost little.")
                    }
                }
                if draft.knowledgeCharacters > PromptComposer.defaultKnowledgeBudget {
                    Label(
                        "Saaa reads the first \(PromptComposer.defaultKnowledgeBudget.formatted()) characters during a call, in the order listed. Keep what matters most at the top.",
                        systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(saaa.emberText)
                }
                ForEach(importErrors, id: \.self) { error in
                    Label(error, systemImage: "xmark.octagon")
                        .font(.system(size: 12))
                        .foregroundStyle(saaa.dangerText)
                }
            }
            .padding(dropTargeted ? Space.sm : 0)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(dropTargeted ? draft.tint.color : Color.clear))
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls)
                return true
            } isTargeted: { targeted in
                dropTargeted = targeted
            }
        }
    }

    private var summarySection: some View {
        EditorSection(
            "Summary",
            caption: "Every summary has a TL;DR, decisions, action items and open questions. Add the sections this kind of call needs."
        ) {
            TokenEditor(tokens: $draft.summarySections, placeholder: "Add a section, like Pricing or Risks")
            SwitchRow(
                "Draft a follow-up email",
                detail: "A short email you can edit and send after the call.",
                isOn: $draft.draftsFollowUpEmail)
        }
    }

    private var coachingSection: some View {
        EditorSection(
            "Coaching",
            caption: "Talk time, pace and questions are measured on this Mac. The checklist fills in during the call and is scored in the summary."
        ) {
            SwitchRow(
                "Coach me",
                detail: "A nudge when you've talked a while, and what went well and what to try next in the summary.",
                isOn: Binding(get: { draft.coaches }, set: { draft.coaching = $0 }))
            Divider()
            TokenEditor(
                tokens: Binding(get: { draft.checklistItems }, set: { draft.checklist = $0 }),
                placeholder: "Add what to cover, like Budget or Next step agreed")
        }
    }

    private var behaviorSection: some View {
        EditorSection("During the call", caption: nil) {
            SwitchRow(
                "Answer their questions as they come",
                detail: "When someone asks you something, Saaa drafts an answer without a tap. Uses Claude more often.",
                isOn: $draft.autoSuggest)
            Divider()
            SwitchRow(
                "Keep running notes",
                detail: "Decisions, numbers and to-dos, updated as the call goes.",
                isOn: $draft.liveNotes)
            Divider()
            lensRow
        }
    }

    /// How Look frames help with code on this kind of call.
    private var lensRow: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("When you Look at code")
                    .font(.system(size: 13))
                Text(draft.lens.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.lg)
            Picker("When you Look at code", selection: Binding(
                get: { draft.lens },
                set: { draft.screenLens = $0 })) {
                ForEach(ScreenLens.allCases, id: \.self) { lens in
                    Text(lens.title).tag(lens)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var matchingSection: some View {
        EditorSection(
            "Calendar match",
            caption: "When a meeting title contains one of these words, Saaa suggests this playbook."
        ) {
            TokenEditor(tokens: $draft.titleKeywords, placeholder: "Add words like demo, interview or QBR")
        }
    }

    private var manageSection: some View {
        HStack(spacing: Space.md) {
            Button("Duplicate", action: onDuplicate)
                .buttonStyle(.glass)
            Button(isDefault ? "Your default" : "Make default", action: onMakeDefault)
                .buttonStyle(.glass)
                .disabled(isDefault)
            Spacer()
            if isEdited {
                Button("Reset to original…", role: .destructive, action: onRemove)
                    .buttonStyle(.glass)
            } else if !draft.isBuiltIn {
                Button("Delete playbook…", role: .destructive, action: onRemove)
                    .buttonStyle(.glass)
            }
        }
        .padding(.top, Space.sm)
    }

    // MARK: Helpers

    private func addAction(_ action: QuickAction) {
        guard draft.quickActions.count < 8 else { return }
        draft.quickActions.append(action)
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = draft.quickActions.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.quickActions.indices.contains(target) else { return }
        draft.quickActions.swapAt(index, target)
    }

    private func importFiles(_ urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            do {
                draft.knowledge.append(try KnowledgeImporter.item(from: url))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        importErrors = errors
    }
}

// MARK: - Pieces

private struct QuickActionRow: View {
    @Binding var action: QuickAction
    let position: Int
    let count: Int
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    @Environment(\.saaa) private var saaa
    @State private var showSymbols = false

    private static let symbols = [
        "text.bubble", "quote.bubble", "questionmark.bubble", "arrow.counterclockwise",
        "magnifyingglass", "shield.lefthalf.filled", "exclamationmark.shield", "arrow.right.circle",
        "arrow.down.right.circle", "checklist", "number", "person.wave.2", "hand.raised",
        "heart.circle", "lightbulb", "character.book.closed", "sparkles", "list.bullet",
        "pencil", "wand.and.stars", "envelope", "calendar", "dollarsign.circle", "chart.bar",
    ]

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Button {
                showSymbols = true
            } label: {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(saaa.surfaceInset))
            }
            .buttonStyle(.plain)
            .help("Choose a symbol")
            .popover(isPresented: $showSymbols) {
                SymbolGrid(symbols: Self.symbols, selection: $action.symbol, tint: saaa.tideFill)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Space.sm) {
                    TextField("Title", text: $action.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Picker("Kind", selection: $action.kind) {
                        ForEach(QuickAction.Kind.editorOrder, id: \.self) { kind in
                            Text(kind.editorTitle).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Answer actions also power automatic answers.")
                    if position < 4 {
                        KeyCap("⌘\(position + 1)")
                    }
                    Spacer()
                    Button {
                        onMove(-1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(position == 0)
                    .accessibilityLabel("Move up")
                    Button {
                        onMove(1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(position >= count - 1)
                    .accessibilityLabel("Move down")
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove action")
                }
                TextField("What should Saaa do when you tap it?", text: $action.instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .font(.system(size: 12))
            }
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(saaa.surfaceInset.opacity(0.45)))
    }
}

private extension QuickAction.Kind {
    static let editorOrder: [QuickAction.Kind] = [.answer, .say, .ask, .recap, .custom]

    var editorTitle: String {
        switch self {
        case .answer: "Answers a question"
        case .say: "Suggests what to say"
        case .ask: "Suggests a question"
        case .recap: "Recaps"
        case .custom: "Custom"
        }
    }
}

/// A grid of SF Symbols to pick from.
private struct SymbolGrid: View {
    let symbols: [String]
    @Binding var selection: String
    let tint: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 6), spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                Button {
                    selection = symbol
                    dismiss()
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selection == symbol ? tint.opacity(0.25) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
            }
        }
        .padding(Space.md)
    }
}

/// A titled card section in the editor.
private struct EditorSection<Content: View>: View {
    let title: String
    let caption: String?
    let content: Content

    init(_ title: String, caption: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .saaaCard()
    }
}

/// Words as removable chips plus an entry field (comma or Return adds).
struct TokenEditor: View {
    @Binding var tokens: [String]
    let placeholder: String

    @Environment(\.saaa) private var saaa
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !tokens.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        HStack(spacing: 5) {
                            Text(token)
                                .font(.system(size: 12))
                            Button {
                                guard tokens.indices.contains(index) else { return }
                                tokens.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(token)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(saaa.surfaceInset))
                    }
                }
            }
            TextField(placeholder, text: $entry)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .onChange(of: entry) {
                    if entry.contains(",") { commit() }
                }
        }
    }

    private func commit() {
        let parts = entry
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for part in parts where !tokens.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            tokens.append(part)
        }
        entry = ""
    }
}

/// A setting with a title, a line of detail, and a trailing switch.
struct SwitchRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.lg)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
