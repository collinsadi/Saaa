import Core
import EventKit
import Foundation
import os

/// EventKit signals: the calendar event overlapping a call (title, attendees,
/// notes).
public enum CalendarContextModule {
    /// Module identity used in diagnostics and privacy-safe logs.
    public static let name = "CalendarContext"
}

/// Reads the calendar event overlapping the call. Degrades gracefully:
/// denied access or no event simply yields `nil` — never an error surface.
public actor CalendarReader {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "CalendarReader")

    private let store = EKEventStore()
    private var accessRequested = false

    public init() {}

    /// Requests full calendar access on first use (shows the TCC dialog).
    /// Returns whether Saaa can read events.
    public func ensureAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            return true
        }
        guard !accessRequested else { return false }
        accessRequested = true
        // Callback variant keeps the non-Sendable store actor-confined.
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    Self.log.info("calendar access request failed: \(error, privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    /// The most call-like event overlapping `date`, or `nil`.
    public func eventOverlapping(_ date: Date = .now) async -> Core.CalendarContext? {
        guard await ensureAccess() else { return nil }
        let window = DateInterval(
            start: date.addingTimeInterval(-60), end: date.addingTimeInterval(60))
        let predicate = store.predicateForEvents(
            withStart: window.start, end: window.end, calendars: nil)
        let events = store.events(matching: predicate).map { event in
            EventSummary(
                title: event.title ?? "",
                attendees: (event.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString },
                notes: event.notes,
                isAllDay: event.isAllDay,
                attendeeCount: event.attendees?.count ?? 0)
        }
        return Self.pickBest(from: events)
    }

    /// One overlapping event, reduced for ranking (pure, testable).
    public struct EventSummary: Sendable, Equatable {
        public let title: String
        public let attendees: [String]
        public let notes: String?
        public let isAllDay: Bool
        public let attendeeCount: Int

        public init(title: String, attendees: [String], notes: String?, isAllDay: Bool, attendeeCount: Int) {
            self.title = title
            self.attendees = attendees
            self.notes = notes
            self.isAllDay = isAllDay
            self.attendeeCount = attendeeCount
        }
    }

    /// Ranking: skip all-day events (never calls); prefer events WITH
    /// attendees (meetings) over solo blocks; then the most attendees.
    public static func pickBest(from events: [EventSummary]) -> Core.CalendarContext? {
        let timed = events.filter { !$0.isAllDay && !$0.title.isEmpty }
        let best = timed.max { lhs, rhs in
            (lhs.attendeeCount, lhs.notes?.count ?? 0) < (rhs.attendeeCount, rhs.notes?.count ?? 0)
        }
        guard let best else { return nil }
        return Core.CalendarContext(
            title: best.title, attendees: best.attendees, notes: best.notes)
    }
}

/// A calendar event near now, for meeting detection and the Home "Up next".
public struct UpcomingEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [String]
    public let notes: String?
    /// The event carries a video link (Zoom, Meet, Teams, Webex…).
    public let hasConferenceLink: Bool

    public init(id: String, title: String, start: Date, end: Date, attendees: [String], notes: String?, hasConferenceLink: Bool) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.notes = notes
        self.hasConferenceLink = hasConferenceLink
    }

    public var context: Core.CalendarContext {
        Core.CalendarContext(title: title, attendees: attendees, notes: notes)
    }

    /// Worth offering to record: a meeting, not a focus block.
    public var looksLikeAMeeting: Bool {
        hasConferenceLink || !attendees.isEmpty
    }

    static let conferenceHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "whereby.com", "around.co", "facetime.apple.com", "gather.town", "chime.aws",
    ]

    public static func containsConferenceLink(_ texts: [String?]) -> Bool {
        texts.compactMap { $0?.lowercased() }.contains { text in
            conferenceHosts.contains { text.contains($0) }
        }
    }
}

extension CalendarReader {

    /// Whether Saaa can read events (never prompts).
    public static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Timed events overlapping `start...end`, soonest first. Never shows the
    /// permission dialog: without access this is empty.
    public func events(from start: Date, to end: Date) -> [UpcomingEvent] {
        guard Self.hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && !($0.title ?? "").isEmpty }
            .map { event in
                UpcomingEvent(
                    id: "\(event.eventIdentifier ?? "event")-\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    attendees: (event.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString },
                    notes: event.notes,
                    hasConferenceLink: UpcomingEvent.containsConferenceLink(
                        [event.url?.absoluteString, event.location, event.notes]))
            }
            .sorted { $0.start < $1.start }
    }
}
