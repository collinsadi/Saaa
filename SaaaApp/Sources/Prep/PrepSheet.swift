import AppKit
import CalendarContext
import CallSession
import Core
import DesignSystem
import SwiftUI

/// The prep sheet floats above the call without taking it over: a
/// non-activating panel, so the call app stays in front while you type.
final class PrepPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "Call context"
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class PrepPresenter {
    private var panel: PrepPanel?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show(context: SessionContext, playbook: Playbook?) {
        panel?.close()
        let chosen = playbook ?? (model.session.isLive ? model.session.playbook : model.playbooks.defaultPlaybook)
        let panel = PrepPanel()
        let view = PrepSheet(model: model, context: context, playbook: chosen) { [weak self] in
            self?.close()
        }
        .saaaThemed()
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.center()
        ScreenPrivacy.shared.register(panel, as: .prep)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

/// Title, goal, who's on the call, notes, and the playbook. All optional:
/// whatever is here shapes every answer.
struct PrepSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @Environment(\.saaa) private var saaa
    @State private var context: SessionContext
    @State private var playbookID: String
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title, goal, participants, notes
    }

    init(model: AppModel, context: SessionContext, playbook: Playbook, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _context = State(initialValue: context)
        _playbookID = State(initialValue: playbook.id)
    }

    private var isLive: Bool { model.session.isLive }

    private var playbook: Playbook {
        model.playbooks.playbook(id: playbookID) ?? model.playbooks.defaultPlaybook
    }

    private var calendarEvent: UpcomingEvent? {
        model.detector.suggestion?.event ?? model.detector.upcoming.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            if let event = calendarEvent, context.title.isEmpty || context.participants.isEmpty {
                Button {
                    context = context.filling(from: SessionContext.from(event.context))
                } label: {
                    Label("Fill from \u{201C}\(event.title)\u{201D}", systemImage: "calendar")
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
            }
            field("What's the call?") {
                TextField("Renewal with Dana at Northwind", text: $context.title)
                    .focused($focus, equals: .title)
            }
            field("What would a good outcome be?") {
                TextField("Agree on a two-year term", text: $context.goal, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focus, equals: .goal)
            }
            field("Who's on it?") {
                TextField("Dana Reyes, VP Operations; Sam, procurement", text: $context.participants, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focus, equals: .participants)
            }
            field("Anything Saaa should know?") {
                TextEditor(text: $context.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 110)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(saaa.surfaceInset))
                    .focused($focus, equals: .notes)
            }
            footer
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 540)
        .background(saaa.surfaceBase)
        .onAppear { focus = .title }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isLive ? "Call context" : "Before the call")
                    .font(.system(size: 22, weight: .bold))
                Text(isLive
                    ? "Changes reach the copilot right away."
                    : "All optional. Whatever you add shapes every answer.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(model.playbooks.all) { option in
                    Button {
                        playbookID = option.id
                    } label: {
                        Label(option.name, systemImage: option.symbol)
                    }
                }
            } label: {
                PlaybookBadge(playbook)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Playbook")
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            Button("Cancel", action: onClose)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Spacer()
            KeyCap("⌘↩")
            if isLive {
                Button("Update", action: apply)
                    .buttonStyle(.glassProminent)
                    .tint(saaa.tideFill)
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button(action: start) {
                    Label("Start session", systemImage: "record.circle")
                }
                .buttonStyle(.glassProminent)
                .tint(saaa.tideFill)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.session.isBusy)
            }
        }
        .padding(.top, Space.sm)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var cleaned: SessionContext {
        SessionContext(
            title: context.title.trimmingCharacters(in: .whitespacesAndNewlines),
            goal: context.goal.trimmingCharacters(in: .whitespacesAndNewlines),
            participants: context.participants.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: context.notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func start() {
        model.startSession(playbook: playbook, context: cleaned)
        onClose()
    }

    private func apply() {
        model.session.updateContext(cleaned)
        if playbook.id != model.session.playbook.id {
            model.session.switchPlaybook(playbook)
        }
        onClose()
    }
}
