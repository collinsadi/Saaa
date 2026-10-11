import CalendarContext
import CallSession
import Core
import DesignSystem
import Persistence
import SwiftUI

/// Home: start a session, see what's next on the calendar, pick up recent calls.
struct HomePane: View {
    @Bindable var model: AppModel

    @Environment(\.saaa) private var saaa
    @State private var startPlaybookID: String?

    private var startPlaybook: Playbook {
        startPlaybookID.flatMap { model.playbooks.playbook(id: $0) } ?? model.playbooks.defaultPlaybook
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                PaneHeader(greeting, subtitle: Date.now.formatted(date: .complete, time: .omitted))
                startCard
                if !model.hasAPIKey || !model.encryptionHealthy {
                    setupCard
                }
                upNext
                recent
                footer
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshKeyState() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    // MARK: - Start

    @ViewBuilder
    private var startCard: some View {
        if model.session.isBusy {
            liveCard
        } else {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Start a session")
                            .font(.system(size: 19, weight: .semibold))
                        Text("Join your call first. Saaa hears both sides on this Mac and helps as you talk.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyCap("⌥⌘R")
                }
                HStack(spacing: Space.md) {
                    Menu {
                        ForEach(model.playbooks.all) { playbook in
                            Button {
                                startPlaybookID = playbook.id
                            } label: {
                                Label(playbook.name, systemImage: playbook.symbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            PlaybookBadge(startPlaybook)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    Button {
                        model.openPrep(context: SessionContext(), playbook: startPlaybook)
                    } label: {
                        Label("Add context", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.glass)
                    Spacer()
                    Button {
                        model.startSession(playbook: startPlaybook)
                    } label: {
                        Label("Start", systemImage: "record.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(saaa.tideFill)
                    .controlSize(.large)
                }
                if case .failed(let message) = model.session.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(saaa.dangerText)
                }
            }
            .padding(Space.xl)
            .saaaGlass(cornerRadius: 22, tint: startPlaybook.tint.color.opacity(0.10))
        }
    }

    private var liveCard: some View {
        HStack(spacing: Space.lg) {
            Lamp(model.session.isLive ? .recording : .processing)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.session.isLive ? "Live now" : "Saving the session…")
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: Space.sm) {
                    PlaybookBadge(model.session.playbook, compact: true)
                    Text("· \(CallTime.stamp(model.session.callTime))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let app = model.session.appName {
                        Text("· \(app)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if model.session.isLive {
                Button("Show panel") { model.panelExpanded = true }
                    .buttonStyle(.glass)
                Button("Stop") { model.session.stop() }
                    .buttonStyle(.glassProminent)
                    .tint(saaa.emberLamp)
            }
        }
        .padding(Space.xl)
        .saaaGlass(cornerRadius: 22, tint: saaa.emberLamp.opacity(0.08))
    }

    // MARK: - Setup

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("Finish setting up")
            if !model.hasAPIKey {
                setupRow(
                    symbol: "key.fill", title: "Connect Claude",
                    detail: "Live answers, notes and summaries need your Claude API key, kept on your Saaa server.",
                    action: "Connect") { model.openHub(.settings) }
            }
            if !model.encryptionHealthy {
                setupRow(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Encryption key unavailable",
                    detail: "Saaa couldn't read its encryption key. Sessions from this launch can't be reopened later.",
                    action: nil) {}
            }
        }
        .saaaCard()
    }

    private func setupRow(symbol: String, title: String, detail: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(saaa.tideText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let action {
                Button(action, action: perform).buttonStyle(.glass)
            }
        }
    }

    // MARK: - Up next

    @ViewBuilder
    private var upNext: some View {
        let events = model.detector.upcoming
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("Up next", trailing: events.isEmpty ? nil : "\(events.count) today")
            if !CalendarReader.hasAccess {
                Text("Turn on Calendar access in Settings to see today's meetings here and get a one-click start.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if events.isEmpty {
                Text("No more meetings today.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(events.prefix(6)) { event in
                        eventRow(event)
                        if event.id != events.prefix(6).last?.id {
                            Divider().padding(.leading, 74)
                        }
                    }
                }
                .saaaCard(padding: Space.sm)
            }
        }
    }

    private func eventRow(_ event: UpcomingEvent) -> some View {
        let playbook = PlaybookMatcher.match(title: event.title, in: model.playbooks.all) ?? model.playbooks.defaultPlaybook
        let soon = event.start.timeIntervalSinceNow < 10 * 60
        return HStack(spacing: Space.md) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("\(Int(event.end.timeIntervalSince(event.start) / 60))m")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 58, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if event.hasConferenceLink {
                        Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    PlaybookBadge(playbook, compact: true)
                    if !event.attendees.isEmpty {
                        Text("· \(event.attendees.count) people").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Prep") {
                model.openPrep(context: SessionContext.from(event.context), playbook: playbook)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            if soon, !model.session.isBusy {
                Button("Start") {
                    model.startSession(playbook: playbook, context: SessionContext.from(event.context))
                }
                .buttonStyle(.glassProminent)
                .tint(saaa.tideFill)
                .controlSize(.small)
            }
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.sm)
    }

    // MARK: - Recent

    @ViewBuilder
    private var recent: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                SectionLabel("Recent")
                Spacer()
                if !model.sessions.isEmpty {
                    Button("All sessions") { model.hubPane = .sessions }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(saaa.tideText)
                }
            }
            if model.sessions.isEmpty {
                EmptyStateView(
                    symbol: "waveform",
                    title: "No sessions yet",
                    message: "Your calls land here with a summary, action items and the full transcript.")
                    .saaaCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.md)], spacing: Space.md) {
                    ForEach(model.sessions.prefix(4)) { entry in
                        SessionCard(entry: entry, model: model)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.lg) {
            Label("\(model.sessions.count) sessions", systemImage: "tray.full")
            Label("\(UsageLedger.format(model.monthlyCost)) on Claude this month", systemImage: "chart.bar")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
}

/// A recent-session card.
struct SessionCard: View {
    let entry: SessionIndexEntry
    let model: AppModel

    @Environment(\.saaa) private var saaa

    var body: some View {
        Button {
            model.openSession(entry.id)
        } label: {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    if let playbook = model.playbooks.playbook(id: entry.playbookID) {
                        PlaybookBadge(playbook, compact: true)
                    }
                    Spacer()
                    Text(entry.startedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(entry.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.tldr.isEmpty ? (model.session.summarizing[entry.id] ?? "No summary yet") : entry.tldr)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack(spacing: Space.md) {
                    Label("\(max(1, Int((entry.duration / 60).rounded())))m", systemImage: "clock")
                    if entry.openActionItems > 0 {
                        Label("\(entry.openActionItems)", systemImage: "checklist")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .saaaCard()
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
    }
}
