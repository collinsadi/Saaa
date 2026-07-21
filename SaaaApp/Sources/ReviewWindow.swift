import AppKit
import Core
import SwiftUI

/// The MVP review surface: a plain window showing the attributed transcript.
/// (The token-driven Review & Edit window arrives with the DesignSystem
/// phase; this proves the pipeline end-to-end.)
@MainActor
final class ReviewWindowPresenter {

    private var window: NSWindow?

    func show(_ transcript: Transcript, sessionDirectory: URL?, onClose: @escaping @MainActor () -> Void) {
        let view = ReviewView(
            transcript: transcript,
            sessionDirectory: sessionDirectory,
            onClose: { [weak self] in
                self?.window?.close()
                self?.window = nil
                onClose()
            })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Saaa — Transcript"
        window.setContentSize(NSSize(width: 560, height: 640))
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ReviewView: View {
    let transcript: Transcript
    let sessionDirectory: URL?
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if transcript.segments.isEmpty {
                ContentUnavailableView(
                    "Nothing transcribed",
                    systemImage: "waveform.slash",
                    description: Text("The recording contained no recognizable speech."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                            HStack(alignment: .top, spacing: 8) {
                                Text(label(for: segment))
                                    .fontWeight(.semibold)
                                    .frame(width: 52, alignment: .trailing)
                                Text(segment.text)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(4)
                }
            }
            HStack {
                if let sessionDirectory {
                    Button("Show Files") {
                        NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
                    }
                }
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
    }

    private func label(for segment: TranscriptSegment) -> String {
        switch segment.speaker {
        case .me: "Me"
        case .them(let label): label ?? "Them"
        }
    }
}
