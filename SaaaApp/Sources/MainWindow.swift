import AppKit
import AudioCapture
import CallSession
import Core
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// The launchable hub window (issue #3): import, history, and settings in
/// one place, complementing the ambient island. While the hub is open the
/// app has a Dock presence; closing it returns Saaa to a menu-bar accessory.
@MainActor
final class MainWindowPresenter {

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(controller: CallController, importQueue: ImportQueueModel) {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = MainHubView(controller: controller, importQueue: importQueue)
            .saaaThemed()
        let hosting = NSHostingController(rootView: view)
        // Never let SwiftUI's reported ideal size become window resize
        // constraints — it pins the height (width stays free) and vertical
        // resizing silently dies. The window owns its own limits.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Saaa"
        window.setContentSize(NSSize(width: 960, height: 620))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        // Opacity rides the SwiftUI background, not alphaValue, so text and
        // cards stay at full strength while the base material fades.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()
        self.window = window
        CaptureExclusion.shared.register(window, as: .main)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // Back to menu-bar-only once the hub goes away.
            MainActor.assumeIsolated {
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Import queue

/// Sequential import queue: one file at a time through the live-call
/// pipeline, each ending in Review & Edit; the next starts when the
/// controller returns to idle.
@MainActor
@Observable
final class ImportQueueModel {

    enum ItemStatus: Equatable {
        case waiting
        case processing
        case done
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status: ItemStatus = .waiting
    }

    private(set) var items: [Item] = []
    var context = CallController.ImportContext()
    private var currentID: UUID?

    var hasPending: Bool { items.contains { $0.status == .waiting } }

    /// Adds dropped/picked URLs (folders expand one level, importable
    /// files only) and starts the queue when the controller is free.
    func add(_ urls: [URL], controller: CallController) {
        items += MediaImporter.expand(urls).map { Item(url: $0) }
        startNextIfFree(controller: controller)
    }

    /// Drives the queue off the session state: review closed or error
    /// acknowledged means the pipeline is free again.
    func stateChanged(_ state: SessionState, controller: CallController) {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else {
            startNextIfFree(controller: controller)
            return
        }
        switch state {
        case .done, .idle:
            items[index].status = .done
            self.currentID = nil
            startNextIfFree(controller: controller)
        case .error(let message):
            items[index].status = .failed(message)
            self.currentID = nil
            startNextIfFree(controller: controller)
        default:
            break
        }
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.status {
            case .done, .failed: true
            case .waiting, .processing: false
            }
        }
    }

    private func startNextIfFree(controller: CallController) {
        guard currentID == nil else { return }
        switch controller.state {
        case .idle, .done, .error: break
        default: return
        }
        guard let index = items.firstIndex(where: { $0.status == .waiting }) else { return }
        items[index].status = .processing
        currentID = items[index].id
        controller.importRecording(items[index].url, context: context)
    }
}

// MARK: - Hub view

private enum HubPane: String, CaseIterable, Identifiable {
    case importFiles
    case prompts
    case history
    case settings

    var id: String { rawValue }

    var label: (title: String, icon: String) {
        switch self {
        case .importFiles: ("Import", "square.and.arrow.down")
        case .prompts: ("Prompts", "text.quote")
        case .history: ("History", "clock")
        case .settings: ("Settings", "gearshape")
        }
    }
}

struct MainHubView: View {
    let controller: CallController
    let importQueue: ImportQueueModel

    @Environment(\.saaa) private var saaa
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("hubOpacity") private var hubOpacity = 1.0
    @AppStorage("hubFadeWhenInactive") private var fadeWhenInactive = false
    @State private var pane: HubPane = .importFiles

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider().overlay(saaa.borderHairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(saaa.surfaceBase.opacity(HubOpacityPolicy.effective(
            userOpacity: hubOpacity,
            reduceTransparency: reduceTransparency,
            isInactive: activeState == .inactive,
            fadeWhenInactive: fadeWhenInactive)))
        .onChange(of: controller.state) { _, newState in
            importQueue.stateChanged(newState, controller: controller)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.md) {
                BrandMark(size: 16)
                Text("Saaa")
                    .font(SaaaFont.title2)
                    .foregroundStyle(saaa.textPrimary)
                Spacer()
            }
            InvisibleModeBadge(surface: .main)
                .padding(.bottom, Space.sm)
            .padding(.bottom, Space.xl)
            ForEach(HubPane.allCases) { item in
                Button {
                    pane = item
                } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: item.label.icon)
                            .frame(width: 18)
                        Text(item.label.title)
                            .font(SaaaFont.body)
                        Spacer()
                    }
                    .foregroundStyle(pane == item ? saaa.tideText : saaa.textSecondary)
                    .padding(.horizontal, Space.md)
                    .frame(height: Size.controlLg)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(pane == item ? saaa.surfaceInset : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(Space.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .importFiles:
            ImportPane(controller: controller, queue: importQueue)
        case .prompts:
            PromptsPane(controller: controller)
        case .history:
            HistoryView(embedded: true)
        case .settings:
            ScrollView {
                HStack {
                    Spacer(minLength: 0)
                    SaaaSettingsView(controller: controller, embedded: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Import pane

private struct ImportPane: View {
    let controller: CallController
    let queue: ImportQueueModel

    @Environment(\.saaa) private var saaa
    @State private var pickerPresented = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Import a recording")
                .font(SaaaFont.title2)
                .foregroundStyle(saaa.textPrimary)
            Text("Audio or video runs through the same pipeline as a live call: transcribed on this Mac, matched, reviewed, and sealed. Stereo files keep their two sides; mono files import as one speaker. Only import recordings everyone consented to.")
                .font(SaaaFont.callout)
                .foregroundStyle(saaa.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            contextFields
            dropZone

            if !queue.items.isEmpty {
                queueList
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
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
        .frame(height: 170)
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

    private var queueList: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Queue").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
                Spacer()
                Button("Clear finished") { queue.clearFinished() }
                    .buttonStyle(.plain)
                    .font(SaaaFont.caption)
                    .foregroundStyle(saaa.textTertiary)
            }
            ScrollView {
                VStack(spacing: Space.xs) {
                    ForEach(queue.items) { item in
                        queueRow(item)
                    }
                }
            }
        }
    }

    private func queueRow(_ item: ImportQueueModel.Item) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: "waveform")
                .foregroundStyle(saaa.textTertiary)
            Text(item.url.lastPathComponent)
                .font(SaaaFont.body)
                .foregroundStyle(saaa.textPrimary)
                .lineLimit(1)
            Spacer()
            statusChip(item.status)
        }
        .padding(.horizontal, Space.md)
        .frame(height: Size.controlLg)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(saaa.surfaceRaised))
    }

    @ViewBuilder
    private func statusChip(_ status: ImportQueueModel.ItemStatus) -> some View {
        switch status {
        case .waiting:
            Text("waiting").engravedLabelStyle().foregroundStyle(saaa.textTertiary)
        case .processing:
            Text(controller.processingDetail.isEmpty ? "processing" : controller.processingDetail)
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.tideText)
                .lineLimit(1)
        case .done:
            Text("done").engravedLabelStyle().foregroundStyle(saaa.successText)
        case .failed(let message):
            Text(message)
                .font(SaaaFont.monoCaption)
                .foregroundStyle(saaa.dangerText)
                .lineLimit(1)
                .help(message)
        }
    }
}
