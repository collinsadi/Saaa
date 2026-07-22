import AppKit
import CallSession
import Core
import DesignSystem
import Persistence
import SwiftUI
import Transcription

/// The hub's Prompts pane (issue #2): edit transcription vocabulary and
/// filing instructions across scopes, insert presets, and preview exactly
/// what will be injected. Text saves through the encrypted store with a
/// short debounce.
struct PromptsPane: View {
    let controller: CallController

    @Environment(\.saaa) private var saaa
    @State private var kind: PromptKind = .filing
    @State private var scope: ScopeChoice = .global
    @State private var projectPath = ""
    @State private var callType = "technical"
    @State private var text = ""
    @State private var knownProjects: [String] = []
    @State private var previewShown = false

    enum ScopeChoice: String, CaseIterable, Identifiable {
        case global, project, callType, nextCall
        var id: String { rawValue }

        var label: String {
            switch self {
            case .global: "Global"
            case .project: "Project"
            case .callType: "Call type"
            case .nextCall: "Next call"
            }
        }
    }

    private static let callTypes = ["technical", "client_preference", "standup", "other"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("Custom prompts")
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Text("Vocabulary primes local transcription toward your names and jargon. Filing instructions shape how the agent classifies and extracts. Both are sealed on this Mac.")
                    .font(SaaaFont.callout)
                    .foregroundStyle(saaa.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                pickers
                editor
                footerRow
                if previewShown {
                    preview
                }
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            knownProjects = controller.knownProjectPaths()
            if projectPath.isEmpty { projectPath = knownProjects.first ?? "" }
            reload()
        }
        .onChange(of: kind) { reload() }
        .onChange(of: scope) { reload() }
        .onChange(of: projectPath) { reload() }
        .onChange(of: callType) { reload() }
    }

    // MARK: - Controls

    private var pickers: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Picker("", selection: $kind) {
                    Text("Filing instructions").tag(PromptKind.filing)
                    Text("Vocabulary").tag(PromptKind.vocabulary)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Picker("", selection: $scope) {
                    ForEach(ScopeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Spacer()
            }
            if scope == .project {
                Picker("", selection: $projectPath) {
                    ForEach(knownProjects, id: \.self) { path in
                        Text(URL(filePath: path).lastPathComponent).tag(path)
                    }
                }
                .labelsHidden()
                .frame(width: 320)
            }
            if scope == .callType {
                Picker("", selection: $callType) {
                    ForEach(Self.callTypes, id: \.self) { type in
                        Text(type.replacingOccurrences(of: "_", with: " ")).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 440)
            }
            Text(scopeCaption)
                .font(SaaaFont.caption)
                .foregroundStyle(saaa.textTertiary)
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(kind == .vocabulary ? SaaaFont.monoBody : SaaaFont.body)
            .foregroundStyle(saaa.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(Space.md)
            .frame(minHeight: 180, maxHeight: 280)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceInset))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(saaa.borderHairline, lineWidth: 1))
            .onChange(of: text) { saveNow() }
    }

    private var footerRow: some View {
        HStack(spacing: Space.lg) {
            if kind == .filing {
                Menu("Insert preset") {
                    ForEach(PromptPreset.all) { preset in
                        Button(preset.name) {
                            text = text.isEmpty ? preset.text : text + "\n\n" + preset.text
                            if scope == .callType { callType = preset.callType }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(SaaaFont.body)
                .foregroundStyle(saaa.tideText)
            }
            Button(previewShown ? "Hide preview" : "Preview what gets injected") {
                previewShown.toggle()
            }
            .buttonStyle(.plain)
            .font(SaaaFont.body)
            .foregroundStyle(saaa.tideText)
            if scope == .project, kind == .filing {
                Button("Copy as repo block") { copyRepoBlock() }
                    .buttonStyle(.plain)
                    .font(SaaaFont.body)
                    .foregroundStyle(saaa.tideText)
            }
            Spacer()
            Text(kind == .filing
                ? "Variables: {project} {attendees} {date}"
                : "Comma or newline separated terms")
                .font(SaaaFont.caption)
                .foregroundStyle(saaa.textTertiary)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(kind == .filing
                ? "Instructions block the agent will receive (sample variables)"
                : "Vocabulary prompt local transcription will receive")
                .engravedLabelStyle()
                .foregroundStyle(saaa.textTertiary)
            Text(previewText)
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceRaised))
        }
    }

    private var previewText: String {
        guard let store = controller.prompts else { return "Encrypted store unavailable." }
        switch kind {
        case .filing:
            let composed = PromptResolver.composeFiling(
                global: store.text(.filing, scope: .global),
                project: store.text(.filing, scope: .project(path: projectPath)),
                callTypeBlocks: store.callTypeBlocks(.filing),
                nextCall: store.text(.filing, scope: .nextCall))
            guard let composed else { return "Nothing set yet on any scope." }
            return PromptTemplate.render(
                composed,
                project: projectPath.isEmpty
                    ? "example-project" : URL(filePath: projectPath).lastPathComponent,
                attendees: ["Jane", "Collins"],
                date: .now)
        case .vocabulary:
            let terms = PromptResolver.vocabularyTerms([
                store.text(.vocabulary, scope: .global),
                store.text(.vocabulary, scope: .project(path: projectPath)),
                store.text(.vocabulary, scope: .nextCall),
            ])
            return VocabularyBias.initialPrompt(terms: terms)
                ?? "Nothing set yet on any scope."
        }
    }

    // MARK: - Persistence plumbing

    private var currentScope: PromptScope {
        switch scope {
        case .global: .global
        case .project: .project(path: projectPath)
        case .callType: .callType(callType)
        case .nextCall: .nextCall
        }
    }

    private var scopeCaption: String {
        switch scope {
        case .global: "Applies to every call."
        case .project:
            "Applies when this project is the decided match. Vocabulary applies when a learned meeting link names the project before transcription."
        case .callType: "Applied by the agent only when it classifies the call as this type."
        case .nextCall: "One time: consumed by the next processed call, then cleared."
        }
    }

    private func reload() {
        guard let store = controller.prompts else { return }
        text = store.text(kind, scope: currentScope) ?? ""
    }

    /// Write-through on every change: the payload is tiny, sealing is
    /// cheap, and there is no debounce window to lose an edit in.
    private func saveNow() {
        controller.prompts?.set(kind, scope: currentScope, text: text)
    }

    private func copyRepoBlock() {
        let block = """
        ## Saaa filing instructions

        \(text)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block, forType: .string)
    }
}
