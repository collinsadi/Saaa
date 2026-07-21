import SwiftUI
import AudioCapture
import CalendarContext
import CallSession
import ClaudeBridge
import Core
import DesignSystem
import Extraction
import Matching
import Persistence
import Transcription

/// Saaa — every call, in context.
///
/// Phase-1 scaffold: a menu-bar presence proving the app target, the ten local
/// packages, entitlements, and Swift 6 strict concurrency all build and link.
/// The notch island, capture engine, and windows arrive in later phases.
@main
struct SaaaApp: App {
    var body: some Scene {
        MenuBarExtra("Saaa", systemImage: "waveform") {
            MenuBarPlaceholderView()
        }
    }
}

struct MenuBarPlaceholderView: View {
    var body: some View {
        Text("Saaa — scaffold build")
        Divider()
        Button("Quit Saaa") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
