import Core
import Foundation
import os

/// The encrypted session library: one sealed `session.enc` per session
/// folder plus an encrypted index (`library.enc`) for fast listing and
/// search. All file work runs on this actor.
public actor SessionLibrary {

    public enum LibraryError: Error, Equatable {
        case notFound
        case unreadable(String)
    }

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "SessionLibrary")

    public nonisolated let root: URL
    private let encryption: EncryptionService
    private var index: [SessionIndexEntry]?
    /// Every session as one search index for Memory; rebuilt after changes.
    private var memory: MemoryIndex?

    public init(root: URL = PersistenceModule.defaultRoot, encryption: EncryptionService) {
        self.root = root
        self.encryption = encryption
    }

    public nonisolated var sessionsDirectory: URL {
        root.appendingPathComponent("Sessions", isDirectory: true)
    }

    private var indexURL: URL { root.appendingPathComponent("library.enc") }

    // MARK: - Reading

    /// All sessions, newest first.
    public func entries() -> [SessionIndexEntry] {
        loadIndex().sorted { $0.startedAt > $1.startedAt }
    }

    /// Decrypts one session.
    public func record(_ id: UUID) throws -> SessionRecord {
        guard let entry = loadIndex().first(where: { $0.id == id }) else { throw LibraryError.notFound }
        return try readRecord(folder: entry.folder)
    }

    /// Title / playbook / TL;DR match, then (deep) transcript and summary text.
    public func search(_ query: String, deep: Bool = true) -> [SessionIndexEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = entries()
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            if entry.matches(needle) { return true }
            guard deep, let record = try? readRecord(folder: entry.folder) else { return false }
            if record.transcript.segments.contains(where: { $0.text.lowercased().contains(needle) }) { return true }
            if let summary = record.summary, summary.markdown().lowercased().contains(needle) { return true }
            return record.context.participants.lowercased().contains(needle)
        }
    }

    /// Memory: every session's summary, prep and transcript as a search
    /// index, built here on the Mac and kept until the library changes.
    /// Unreadable archives are skipped.
    public func memoryIndex() -> MemoryIndex {
        if let memory { return memory }
        let sources = entries().compactMap { entry in
            (try? readRecord(folder: entry.folder)).map(MemorySource.init(record:))
        }
        let built = MemoryIndex(sources: sources)
        memory = built
        return built
    }

    /// Cost of sessions started in the month containing `date`.
    public func monthlyCost(containing date: Date = .now, calendar: Calendar = .current) -> Double {
        loadIndex()
            .filter { calendar.isDate($0.startedAt, equalTo: date, toGranularity: .month) }
            .reduce(0) { $0 + $1.costUSD }
    }

    // MARK: - Writing

    /// A fresh, unique folder for a new session (audio + archive live there).
    public func makeFolder(startedAt: Date, suffix: String? = nil) throws -> (name: String, url: URL) {
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let stamp = Self.folderStamp(startedAt)
        var name = suffix.map { "\(stamp)-\($0)" } ?? stamp
        var counter = 2
        while FileManager.default.fileExists(atPath: sessionsDirectory.appendingPathComponent(name).path) {
            name = (suffix.map { "\(stamp)-\($0)" } ?? stamp) + "-\(counter)"
            counter += 1
        }
        let url = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (name, url)
    }

    /// Seals `record` into `folder` and updates the index.
    @discardableResult
    public func save(_ record: SessionRecord, folder: String) throws -> SessionIndexEntry {
        let directory = sessionsDirectory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encryption.encrypt(record, to: directory.appendingPathComponent("session.enc"))
        let entry = SessionIndexEntry(record: record, folder: folder)
        var entries = loadIndex()
        entries.removeAll { $0.id == record.id }
        entries.append(entry)
        try writeIndex(entries)
        return entry
    }

    /// Re-seals an existing session after edits (summary, chat, checkboxes).
    @discardableResult
    public func update(_ record: SessionRecord) throws -> SessionIndexEntry {
        guard let entry = loadIndex().first(where: { $0.id == record.id }) else { throw LibraryError.notFound }
        return try save(record, folder: entry.folder)
    }

    /// Deletes a session's folder (archive and any audio) and its index row.
    public func delete(_ id: UUID) throws {
        var entries = loadIndex()
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let directory = sessionsDirectory.appendingPathComponent(entry.folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        entries.removeAll { $0.id == id }
        try writeIndex(entries)
    }

    /// Erases every session and the index.
    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: sessionsDirectory.path) {
            try FileManager.default.removeItem(at: sessionsDirectory)
        }
        try? FileManager.default.removeItem(at: indexURL)
        index = []
        memory = nil
    }

    // MARK: - Migration

    /// Adopts sealed sessions from the pre-rebuild app (and any folder whose
    /// index row was lost). Returns how many were added.
    @discardableResult
    public func adoptUnindexedSessions() -> Int {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }
        var entries = loadIndex()
        let known = Set(entries.map(\.folder))
        var added = 0
        for folder in folders where !known.contains(folder.lastPathComponent) {
            let archive = folder.appendingPathComponent("session.enc")
            guard FileManager.default.fileExists(atPath: archive.path),
                  let record = try? readRecord(folder: folder.lastPathComponent) else { continue }
            entries.append(SessionIndexEntry(record: record, folder: folder.lastPathComponent))
            added += 1
        }
        if added > 0 {
            try? writeIndex(entries)
            Self.log.info("adopted \(added, privacy: .public) sessions into the library")
        }
        return added
    }

    // MARK: - Internals

    private func loadIndex() -> [SessionIndexEntry] {
        if let index { return index }
        let loaded = (try? encryption.decrypt([SessionIndexEntry].self, from: indexURL)) ?? []
        index = loaded
        return loaded
    }

    private func writeIndex(_ entries: [SessionIndexEntry]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encryption.encrypt(entries, to: indexURL)
        index = entries
        memory = nil
    }

    private func readRecord(folder: String) throws -> SessionRecord {
        let url = sessionsDirectory.appendingPathComponent(folder).appendingPathComponent("session.enc")
        let data: Data
        do {
            data = try encryption.decrypt(try Data(contentsOf: url))
        } catch {
            throw LibraryError.unreadable("archive could not be opened")
        }
        if let record = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            return record
        }
        if let legacy = try? JSONDecoder().decode(LegacyArchive.self, from: data) {
            return legacy.record(folder: folder)
        }
        throw LibraryError.unreadable("unknown archive format")
    }

    static func folderStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func date(fromFolder name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(name.prefix(15)))
    }
}

/// The pre-rebuild archive shape (transcript, calendar, matching, filing
/// judgment, Live Assist thread). Only what still matters is read; unknown
/// keys are ignored by the decoder.
struct LegacyArchive: Decodable {
    struct AssistEntry: Decodable {
        var role: String
        var mode: String?
        var text: String
        var at: Date
    }

    var transcript: Transcript
    var calendar: CalendarContext?
    var assistThread: [AssistEntry]?

    func record(folder: String) -> SessionRecord {
        let startedAt = SessionLibrary.date(fromFolder: folder) ?? .now
        let duration = transcript.segments.map(\.end).max() ?? 0
        let thread = (assistThread ?? []).filter { $0.role == "answer" }.map { entry in
            CopilotExchange(
                kind: .action, title: entry.mode ?? "Assist", response: entry.text,
                callTime: max(0, entry.at.timeIntervalSince(startedAt)), createdAt: entry.at)
        }
        return SessionRecord(
            id: Self.stableID(folder),
            startedAt: startedAt,
            duration: duration,
            title: calendar?.title ?? "",
            playbookID: Playbook.generalID,
            playbookName: Playbook.general.name,
            context: calendar.map(SessionContext.from) ?? SessionContext(),
            transcript: transcript,
            thread: thread,
            source: .legacy,
            audioRetained: false)
    }

    /// Same folder → same id, so re-adoption never duplicates.
    static func stableID(_ folder: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in folder.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension MemorySource {
    /// What Memory searches in a session: the summary (or the live notes
    /// when there's no summary yet), the prep and the transcript. Coaching
    /// feedback and the copilot's answers stay out.
    public init(record: SessionRecord) {
        var summary: [String] = []
        if let written = record.summary {
            if !written.tldr.isEmpty { summary.append("TL;DR: \(written.tldr)") }
            summary += written.keyPoints.map { "Key point: \($0)" }
            summary += written.decisions.map { "Decision: \($0)" }
            summary += written.actionItems.map { item in
                var line = "Action item: \(item.text)"
                let tags = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
                if !tags.isEmpty { line += " (\(tags.joined(separator: ", ")))" }
                if item.done { line += " [done]" }
                return line
            }
            summary += written.openQuestions.map { "Open question: \($0)" }
            for section in written.sections {
                summary += section.bullets.map { "\(section.title): \($0)" }
            }
            if let checklist = written.checklist {
                summary += checklist.filter(\.covered).map { "Covered \($0.item): \($0.evidence)" }
            }
        } else if let notes = record.notes {
            summary += notes.keyPoints.map { "Key point: \($0)" }
            summary += notes.decisions.map { "Decision: \($0)" }
            summary += notes.actionItems.map { "Action item: \($0)" }
            summary += notes.openQuestions.map { "Open question: \($0)" }
        }
        var prep: [String] = []
        let goal = record.context.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { prep.append("Goal: \(goal)") }
        let notes = record.context.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { prep.append("Prep notes: \(notes)") }
        self.init(
            id: record.id, title: record.displayTitle, startedAt: record.startedAt, playbookName: record.playbookName,
            participants: record.context.participants, summary: summary, prep: prep, segments: record.transcript.segments)
    }
}
