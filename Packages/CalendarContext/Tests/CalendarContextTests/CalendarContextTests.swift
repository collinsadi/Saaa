import Core
import Testing
@testable import CalendarContext

@Test func moduleLinksAndReportsIdentity() {
    #expect(CalendarContextModule.name == "CalendarContext")
}

@Suite struct EventPickingTests {

    private func event(
        _ title: String, attendees: Int = 0, allDay: Bool = false, notes: String? = nil
    ) -> CalendarReader.EventSummary {
        .init(
            title: title,
            attendees: (0..<attendees).map { "person\($0)@acme.com" },
            notes: notes, isAllDay: allDay, attendeeCount: attendees)
    }

    @Test func prefersMeetingsOverSoloBlocks() {
        let best = CalendarReader.pickBest(from: [
            event("Focus time"),
            event("Acme sync", attendees: 3),
        ])
        #expect(best?.title == "Acme sync")
        #expect(best?.attendees.count == 3)
    }

    @Test func skipsAllDayEvents() {
        let best = CalendarReader.pickBest(from: [
            event("Company holiday", allDay: true),
            event("1:1 with Jane", attendees: 1),
        ])
        #expect(best?.title == "1:1 with Jane")
    }

    @Test func nilWhenNothingUsable() {
        #expect(CalendarReader.pickBest(from: []) == nil)
        #expect(CalendarReader.pickBest(from: [event("Vacation", allDay: true)]) == nil)
    }

    @Test func signalTermsExtractUsefulTokens() {
        let context = Core.CalendarContext(
            title: "Acme Corp — API integration",
            attendees: ["jane@acme.com", "Collins Adi"])
        let terms = context.signalTerms.map { $0.lowercased() }
        #expect(terms.contains("acme"))
        #expect(terms.contains("api"))
        #expect(terms.contains("jane"))
        #expect(terms.contains("collins"))
        #expect(!terms.contains("com"))
    }
}

@Suite struct UpcomingEventTests {

    @Test func detectsConferenceLinks() {
        #expect(UpcomingEvent.containsConferenceLink([nil, "https://acme.zoom.us/j/123", nil]))
        #expect(UpcomingEvent.containsConferenceLink(["Join: meet.google.com/abc-defg-hij"]))
        #expect(!UpcomingEvent.containsConferenceLink(["Room 4B", nil]))
    }

    @Test func meetingHeuristic() {
        let focus = UpcomingEvent(id: "1", title: "Focus", start: .now, end: .now, attendees: [], notes: nil, hasConferenceLink: false)
        let call = UpcomingEvent(id: "2", title: "Sync", start: .now, end: .now, attendees: ["Sam"], notes: nil, hasConferenceLink: false)
        #expect(!focus.looksLikeAMeeting)
        #expect(call.looksLikeAMeeting)
        #expect(call.context.title == "Sync")
    }
}
