import AppKit
import AudioCapture
import CalendarContext
import Core
import Foundation
import Observation

/// Notices when a meeting is starting (a calendar event with people or a
/// video link, or a conferencing app playing audio) and offers a one-click
/// start on the island. It only ever *offers*: recording is always started
/// by the user.
@MainActor
@Observable
public final class MeetingDetector {

    public struct Suggestion: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// Where it came from, for the island's subtitle.
        public let source: String
        public let event: UpcomingEvent?
    }

    public private(set) var suggestion: Suggestion?
    /// Today's remaining meetings (Home's "Up next").
    public private(set) var upcoming: [UpcomingEvent] = []

    @ObservationIgnored private let calendar = CalendarReader()
    @ObservationIgnored private var dismissed: [String: Date] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// Dedicated conferencing apps. Browsers only count alongside a calendar meeting.
    nonisolated static let conferencingApps = [
        "us.zoom", "com.microsoft.teams", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
    ]

    public init(defaults: UserDefaults = .standard, isBusy: @escaping @MainActor () -> Bool) {
        self.defaults = defaults
        self.isBusy = isBusy
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Hides the current suggestion for 30 minutes.
    public func dismiss() {
        if let suggestion { dismissed[suggestion.id] = .now }
        suggestion = nil
    }

    /// Re-evaluates now (after a session ends, settings change...).
    public func refresh() {
        Task { await evaluate() }
    }

    func evaluate() async {
        let now = Date.now
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        let events = await calendar.events(from: now.addingTimeInterval(-15 * 60), to: endOfDay)
        upcoming = events.filter { $0.end > now && $0.looksLikeAMeeting }
        guard SaaaSettings.meetingDetection(defaults), !isBusy() else {
            suggestion = nil
            return
        }
        dismissed = dismissed.filter { now.timeIntervalSince($0.value) < 30 * 60 }
        let apps = Self.audioApps()
        suggestion = Self.decide(events: events, activeApps: apps, now: now, dismissed: Set(dismissed.keys))
    }

    /// Pure decision: an event starting now beats an app signal.
    nonisolated static func decide(
        events: [UpcomingEvent], activeApps: [(bundleID: String, name: String)],
        now: Date, dismissed: Set<String>
    ) -> Suggestion? {
        let live = events.first { event in
            event.looksLikeAMeeting && !dismissed.contains(event.id)
                && event.start <= now.addingTimeInterval(3 * 60)
                && event.start >= now.addingTimeInterval(-10 * 60)
                && event.end > now
        }
        if let live {
            return Suggestion(id: live.id, title: live.title, source: live.hasConferenceLink ? "Video call" : "Calendar", event: live)
        }
        if let app = activeApps.first(where: { app in conferencingApps.contains { app.bundleID.hasPrefix($0) } }),
           !dismissed.contains("app.\(app.bundleID)") {
            return Suggestion(id: "app.\(app.bundleID)", title: "\(app.name) call", source: app.name, event: nil)
        }
        return nil
    }

    static func audioApps() -> [(bundleID: String, name: String)] {
        let apps = (try? AudioProcessDirectory.appLevelSnapshot(
            excluding: ProcessInfo.processInfo.processIdentifier)) ?? []
        return apps.filter(\.isPlayingAudio).compactMap { entry in
            guard let bundleID = NSRunningApplication(processIdentifier: entry.id)?.bundleIdentifier else { return nil }
            return (bundleID, entry.name)
        }
    }
}
