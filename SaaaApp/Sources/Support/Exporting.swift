import AppKit
import CallSession
import Persistence
import UniformTypeIdentifiers

/// Copy, save-to-folder and export for a sealed session.
@MainActor
enum Exporting {

    static func copyMarkdown(_ record: SessionRecord, includeTranscript: Bool = false) {
        let text = SessionExporter.markdown(record, options: .init(includeTranscript: includeTranscript))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The remembered "Save to folder" destination, if still present.
    static var savedFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: SaaaSettings.saveFolderKey), !path.isEmpty else { return nil }
        let url = URL(filePath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Where should Saaa save meeting notes? A repo's docs folder or a notes vault works well."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: SaaaSettings.saveFolderKey)
        return url
    }

    /// Writes the session as Markdown into the notes folder (asking once).
    @discardableResult
    static func saveToFolder(_ record: SessionRecord) -> URL? {
        guard let folder = savedFolder ?? chooseFolder() else { return nil }
        let url = folder.appendingPathComponent(SessionExporter.fileName(for: record, extension: "md"))
        let text = SessionExporter.markdown(record, options: .init(includeTranscript: true))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            NSSound.beep()
            return nil
        }
    }

    enum Format: String, CaseIterable, Identifiable {
        case markdown = "Markdown"
        case html = "HTML"
        var id: String { rawValue }
    }

    static func export(_ record: SessionRecord, format: Format, options: SessionExporter.Options) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SessionExporter.fileName(for: record, extension: format == .html ? "html" : "md")
        panel.allowedContentTypes = format == .html ? [.html] : [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .html
            ? SessionExporter.html(record, options: options)
            : SessionExporter.markdown(record, options: options)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
