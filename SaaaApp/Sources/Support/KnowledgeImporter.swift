import AppKit
import Core
import PDFKit
import UniformTypeIdentifiers

/// Turns reference files into plain-text knowledge for a playbook. Text is
/// extracted on this Mac; the file itself is never stored or sent.
enum KnowledgeImporter {

    static var allowedTypes: [UTType] {
        var types: [UTType] = [.plainText, .pdf, .rtf, .html, .commaSeparatedText, .json]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        return types
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) couldn't be read."
            case .empty(let name): "\(name) has no text Saaa can use."
            }
        }
    }

    static func item(from url: URL) throws -> KnowledgeItem {
        let name = url.lastPathComponent
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw ImportError.unreadable(name) }
            text = document.string ?? ""
        case "rtf", "rtfd", "html", "htm", "doc", "docx":
            guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw ImportError.unreadable(name)
            }
            text = attributed.string
        default:
            guard let contents = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
                throw ImportError.unreadable(name)
            }
            text = contents
        }
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ImportError.empty(name) }
        return KnowledgeItem(name: name, text: cleaned)
    }

    /// Asks for files and imports what it can; returns items and any errors.
    @MainActor
    static func pick() -> (items: [KnowledgeItem], errors: [String]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedTypes
        panel.message = "Add reference material: pricing, FAQs, rubrics, notes. Saaa keeps the text, encrypted."
        guard panel.runModal() == .OK else { return ([], []) }
        var items: [KnowledgeItem] = []
        var errors: [String] = []
        for url in panel.urls {
            do {
                items.append(try item(from: url))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return (items, errors)
    }
}
