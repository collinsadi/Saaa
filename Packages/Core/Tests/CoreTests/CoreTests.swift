import Foundation
import Testing
@testable import Core

@Test func moduleLinksAndReportsIdentity() {
    #expect(CoreModule.name == "Core")
}

@Test func callTimeStamps() {
    #expect(CallTime.stamp(0) == "00:00")
    #expect(CallTime.stamp(75.9) == "01:15")
    #expect(CallTime.stamp(3_725) == "1:02:05")
    #expect(CallTime.stamp(-3) == "00:00")
}

@Suite struct PlaybookTests {

    @Test func builtInsAreWellFormed() {
        let playbooks = Playbook.builtIns
        #expect(playbooks.count == 9)
        #expect(Set(playbooks.map(\.id)).count == playbooks.count)
        for playbook in playbooks {
            #expect(playbook.isBuiltIn)
            #expect(!playbook.instructions.isEmpty)
            #expect((2...6).contains(playbook.quickActions.count))
            #expect(Set(playbook.quickActions.map(\.id)).count == playbook.quickActions.count)
            if playbook.autoSuggest {
                #expect(playbook.quickActions.contains { $0.kind == .answer })
            }
        }
        #expect(Playbook.builtIns.first?.id == Playbook.generalID)
    }

    @Test func recruitingStaysOnTheInterviewerSide() {
        let text = Playbook.recruiting.instructions.lowercased()
        #expect(text.contains("i'm interviewing"))
        #expect(text.contains("protected characteristic"))
    }

    @Test func duplicateIsEditableAndUnique() {
        let copy = Playbook.sales.duplicated()
        #expect(!copy.isBuiltIn)
        #expect(copy.id != Playbook.sales.id)
        #expect(copy.id.hasPrefix("custom."))
        #expect(copy.name == "Sales copy")
    }

    @Test func matcherPicksByCalendarTitle() {
        let all = Playbook.builtIns
        #expect(PlaybookMatcher.match(title: "Acme <> Saaa demo", in: all)?.id == "builtin.sales")
        #expect(PlaybookMatcher.match(title: "Interview: Jane Doe (Backend)", in: all)?.id == "builtin.recruiting")
        #expect(PlaybookMatcher.match(title: "Daily standup", in: all)?.id == "builtin.standup")
        #expect(PlaybookMatcher.match(title: "1:1 Collins / Sam", in: all)?.id == "builtin.oneonone")
        #expect(PlaybookMatcher.match(title: "Lunch", in: all) == nil)
        #expect(PlaybookMatcher.match(title: "Code review: auth service", in: all)?.id == Playbook.pairingID)
    }

    @Test func lensesDefaultByPlaybookAndSurviveOldData() throws {
        #expect(Playbook.recruiting.lens == .interviewer)
        #expect(Playbook.pairProgramming.lens == .pairProgramming)
        #expect(Playbook.sales.lens == .standard)
        // A Recruiting playbook edited before lenses existed keeps the interviewer lens.
        var old = Playbook.recruiting
        old.screenLens = nil
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("screenLens"))
        let decoded = try JSONDecoder().decode(Playbook.self, from: data)
        #expect(decoded.screenLens == nil)
        #expect(decoded.lens == .interviewer)
        // Duplicates carry the lens to their new id.
        #expect(Playbook.recruiting.duplicated().lens == .interviewer)
    }

    @Test func knowledgeIsCapped() {
        let item = KnowledgeItem(name: "big", text: String(repeating: "a", count: KnowledgeItem.maxCharacters + 50))
        #expect(item.text.count == KnowledgeItem.maxCharacters)
    }

    @Test func playbooksRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(Playbook.builtIns)
        let decoded = try JSONDecoder().decode([Playbook].self, from: data)
        #expect(decoded == Playbook.builtIns)
    }
}

@Suite struct SessionContextTests {

    @Test func calendarPrefillAndFilling() {
        let calendar = CalendarContext(title: "Acme renewal", attendees: ["Dana Lee", "ken@acme.com"], notes: "Agenda: pricing")
        let prefilled = SessionContext.from(calendar)
        #expect(prefilled.participants == "Dana Lee, ken@acme.com")
        let typed = SessionContext(title: "", goal: "Keep them on annual")
        let merged = typed.filling(from: prefilled)
        #expect(merged.title == "Acme renewal")
        #expect(merged.goal == "Keep them on annual")
        #expect(merged.notes == "Agenda: pricing")
        #expect(SessionContext().isEmpty)
        #expect(!merged.isEmpty)
    }

    @Test func vocabularyHintsTakeNamesNotEmails() {
        let context = SessionContext(title: "Northwind Platform review", participants: "Dana Lee (CFO), ken@acme.com; Priya")
        #expect(context.vocabularyHints.contains("Dana Lee"))
        #expect(context.vocabularyHints.contains("Priya"))
        #expect(!context.vocabularyHints.contains { $0.contains("@") })
        #expect(context.vocabularyHints.contains("Northwind"))
    }
}

@Suite struct SummaryAndNotesTests {

    @Test func markdownRendersEverySection() {
        let summary = MeetingSummary(
            title: "Acme renewal", tldr: "They renew if SSO ships.",
            keyPoints: ["Usage up 30%"], decisions: ["Annual plan"],
            actionItems: [.init(text: "Send SSO timeline", owner: "Collins", due: "Fri")],
            openQuestions: ["Who signs?"],
            sections: [.init(title: "Risks", bullets: ["Budget freeze"])],
            followUpEmail: "Hi Dana,\nThanks for today.")
        let markdown = summary.markdown()
        #expect(markdown.hasPrefix("# Acme renewal"))
        #expect(markdown.contains("- [ ] Send SSO timeline (Collins, due Fri)"))
        #expect(markdown.contains("## Risks\n- Budget freeze"))
        #expect(markdown.contains("## Follow-up email draft"))
    }

    @Test func blankOwnersAndEmailsNormalizeToNil() {
        let item = MeetingSummary.ActionItem(text: "x", owner: " ", due: "")
        #expect(item.owner == nil)
        #expect(item.due == nil)
        #expect(MeetingSummary(title: "t", tldr: "", followUpEmail: "  ").followUpEmail == nil)
    }

    @Test func liveNotesRoundTripThroughText() throws {
        let notes = LiveNotes(keyPoints: ["Budget is 50k"], decisions: [], actionItems: ["Send deck (Collins)"], openQuestions: ["Timeline?"])
        let parsed = try #require(LiveNotes.parse(notes.plainText, coveredUntil: 90))
        #expect(parsed.keyPoints == ["Budget is 50k"])
        #expect(parsed.decisions.isEmpty)
        #expect(parsed.actionItems == ["Send deck (Collins)"])
        #expect(parsed.coveredUntil == 90)
    }

    @Test func liveNotesParseToleratesMarkdown() throws {
        let text = """
        ## Key points
        * Pilot starts in May
        **DECISIONS**
        - Go with the annual plan
        Action items:
        - none
        """
        let parsed = try #require(LiveNotes.parse(text, coveredUntil: 0))
        #expect(parsed.keyPoints == ["Pilot starts in May"])
        #expect(parsed.decisions == ["Go with the annual plan"])
        #expect(parsed.actionItems.isEmpty)
        #expect(LiveNotes.parse("Sorry, I can't help.", coveredUntil: 0) == nil)
    }
}

@Suite struct UsageLedgerTests {

    @Test func mergesByRoleAndModel() {
        var ledger = UsageLedger()
        ledger.add(UsageRecord(role: "live", model: "h", inputTokens: 100, outputTokens: 10, cacheReadTokens: 900, costUSD: 0.001))
        ledger.add(UsageRecord(role: "live", model: "h", inputTokens: 50, outputTokens: 5, cacheReadTokens: 950, costUSD: 0.001))
        ledger.add(UsageRecord(role: "summary", model: "s", inputTokens: 2_000, outputTokens: 500, costUSD: 0.009))
        #expect(ledger.records.count == 2)
        #expect(ledger.totalRequests == 3)
        #expect(abs(ledger.totalCostUSD - 0.011) < 1e-9)
        #expect(ledger.cacheHitRatio > 0.4)
        #expect(UsageLedger.format(0.004) == "<$0.01")
        #expect(UsageLedger.format(0.123) == "$0.12")
    }
}

@Suite struct ScreenPrivacyTests {

    @Test func offExcludesNothing() {
        for surface in SaaaSurface.allCases {
            #expect(!ScreenPrivacyPolicy.isExcluded(surface, enabled: false, scope: .allWindows))
        }
    }

    @Test func scopesExcludeTheRightSurfaces() {
        #expect(ScreenPrivacyPolicy.isExcluded(.island, enabled: true, scope: .allWindows))
        #expect(!ScreenPrivacyPolicy.isExcluded(.island, enabled: true, scope: .callContent))
        #expect(ScreenPrivacyPolicy.isExcluded(.livePanel, enabled: true, scope: .callContent))
        #expect(ScreenPrivacyPolicy.isExcluded(.hub, enabled: true, scope: .callContent))
    }

    @Test func storageKeysCarryOverFromInvisibleMode() {
        #expect(ScreenPrivacyPolicy.enabledKey == "invisibleMode")
        #expect(ScreenPrivacyScope(rawValue: "content") == .callContent)
    }
}
