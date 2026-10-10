import CalendarContext
import Foundation
import Testing
@testable import CallSession

@Suite struct MeetingDetectorTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String, startsIn minutes: Double, length: Double = 30, attendees: [String] = ["Sam"], link: Bool = false) -> UpcomingEvent {
        UpcomingEvent(
            id: id, title: "Meeting \(id)", start: now.addingTimeInterval(minutes * 60),
            end: now.addingTimeInterval((minutes + length) * 60), attendees: attendees, notes: nil, hasConferenceLink: link)
    }

    @Test func offersAMeetingThatIsStarting() {
        let suggestion = MeetingDetector.decide(
            events: [event("a", startsIn: 2), event("b", startsIn: 45)], activeApps: [], now: now, dismissed: [])
        #expect(suggestion?.id == "a")
        #expect(suggestion?.event != nil)
    }

    @Test func ignoresFocusBlocksFarFutureAndDismissed() {
        #expect(MeetingDetector.decide(events: [event("solo", startsIn: 0, attendees: [])], activeApps: [], now: now, dismissed: []) == nil)
        #expect(MeetingDetector.decide(events: [event("later", startsIn: 20)], activeApps: [], now: now, dismissed: []) == nil)
        #expect(MeetingDetector.decide(events: [event("a", startsIn: 1)], activeApps: [], now: now, dismissed: ["a"]) == nil)
        #expect(MeetingDetector.decide(events: [event("over", startsIn: -40, length: 30)], activeApps: [], now: now, dismissed: []) == nil)
    }

    @Test func conferencingAppsCountButBrowsersDoNot() {
        let zoom = MeetingDetector.decide(events: [], activeApps: [("us.zoom.xos", "zoom.us")], now: now, dismissed: [])
        #expect(zoom?.id == "app.us.zoom.xos")
        let browser = MeetingDetector.decide(events: [], activeApps: [("com.google.Chrome", "Chrome")], now: now, dismissed: [])
        #expect(browser == nil)
        let dismissed = MeetingDetector.decide(events: [], activeApps: [("us.zoom.xos", "zoom.us")], now: now, dismissed: ["app.us.zoom.xos"])
        #expect(dismissed == nil)
    }
}

@Suite struct SettingsTests {

    @Test func defaultsAreSafe() throws {
        let defaults = try #require(UserDefaults(suiteName: "saaa.settings.\(UUID().uuidString)"))
        #expect(!SaaaSettings.keepsAudio(defaults))
        #expect(SaaaSettings.autoSummary(defaults))
        #expect(SaaaSettings.meetingDetection(defaults))
        #expect(SaaaSettings.consentReminder(defaults))
        defaults.set("fr-FR", forKey: SaaaSettings.localeKey)
        #expect(SaaaSettings.locale(defaults).identifier == "fr-FR")
        #expect(SaaaSettings.disclosureLine.contains("AI notetaker"))
    }
}
