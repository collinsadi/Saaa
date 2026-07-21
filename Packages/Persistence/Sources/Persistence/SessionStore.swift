import Foundation
import SwiftData
import os

/// Content-free metadata row for one recorded call. Content itself lives in
/// the per-session `session.enc` (see ``SessionArchive``), never in the
/// database.
@Model
public final class SessionRecord {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    /// Directory holding session.enc / diagnostics.txt (+ audio if retained).
    public var directoryPath: String
    /// Matched project path, nil == unfiled.
    public var projectPath: String?
    public var confidence: Double?
    public var callType: String?
    /// Whether the raw WAVs were kept (retention setting at process time).
    public var audioRetained: Bool
    /// Lifecycle marker: "review" until the user closes review, then "done".
    public var status: String

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        duration: TimeInterval,
        directoryPath: String,
        projectPath: String?,
        confidence: Double?,
        callType: String?,
        audioRetained: Bool,
        status: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.directoryPath = directoryPath
        self.projectPath = projectPath
        self.confidence = confidence
        self.callType = callType
        self.audioRetained = audioRetained
        self.status = status
    }
}

/// The local store for session metadata (SwiftData/SQLite under Application
/// Support). All access rides this actor.
@ModelActor
public actor SessionStore {

    /// Opens (or creates) the store. Default location:
    /// `~/Library/Application Support/Saaa/store`.
    public init(directory: URL? = nil) throws {
        let dir = directory
            ?? URL.applicationSupportDirectory.appendingPathComponent("Saaa/store", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: dir.appendingPathComponent("sessions.sqlite"))
        let container = try ModelContainer(for: SessionRecord.self, configurations: configuration)
        self.init(modelContainer: container)
    }

    /// Snapshot DTO so callers never touch non-Sendable @Model objects.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let startedAt: Date
        public let duration: TimeInterval
        public let directoryPath: String
        public let projectPath: String?
        public let confidence: Double?
        public let callType: String?
        public let audioRetained: Bool
        public let status: String

        public init(
            id: UUID, startedAt: Date, duration: TimeInterval,
            directoryPath: String, projectPath: String?, confidence: Double?,
            callType: String?, audioRetained: Bool, status: String
        ) {
            self.id = id
            self.startedAt = startedAt
            self.duration = duration
            self.directoryPath = directoryPath
            self.projectPath = projectPath
            self.confidence = confidence
            self.callType = callType
            self.audioRetained = audioRetained
            self.status = status
        }
    }

    public func insert(_ row: Row) throws {
        modelContext.insert(SessionRecord(
            id: row.id, startedAt: row.startedAt, duration: row.duration,
            directoryPath: row.directoryPath, projectPath: row.projectPath,
            confidence: row.confidence, callType: row.callType,
            audioRetained: row.audioRetained, status: row.status))
        try modelContext.save()
    }

    /// Newest first.
    public func all() throws -> [Row] {
        var descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 500
        return try modelContext.fetch(descriptor).map(Self.row(from:))
    }

    public func updateStatus(id: UUID, status: String) throws {
        guard let record = try fetch(id) else { return }
        record.status = status
        try modelContext.save()
    }

    public func delete(id: UUID) throws {
        guard let record = try fetch(id) else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    private func fetch(_ id: UUID) throws -> SessionRecord? {
        var descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func row(from record: SessionRecord) -> Row {
        Row(id: record.id, startedAt: record.startedAt, duration: record.duration,
            directoryPath: record.directoryPath, projectPath: record.projectPath,
            confidence: record.confidence, callType: record.callType,
            audioRetained: record.audioRetained, status: record.status)
    }
}

/// Retention behavior for raw audio. The recommended default deletes WAVs
/// once transcription succeeds — text is retained (encrypted), audio is not.
public struct RetentionPolicy: Sendable, Equatable, Codable {
    public var autoDeleteAudioAfterTranscription: Bool

    public init(autoDeleteAudioAfterTranscription: Bool = true) {
        self.autoDeleteAudioAfterTranscription = autoDeleteAudioAfterTranscription
    }
}
