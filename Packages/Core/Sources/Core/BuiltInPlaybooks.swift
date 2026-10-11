import Foundation

/// The quick actions every playbook builds on.
public enum StandardActions {
    public static let answer = QuickAction(
        id: "answer", title: "Answer", symbol: "text.bubble",
        instruction: """
        Answer the most recent question the other side asked, or the last thing they said that \
        needs a response: one sentence I can say out loud, two at most. Nothing else.
        """,
        kind: .answer)

    public static let whatToSay = QuickAction(
        id: "say", title: "What to say", symbol: "quote.bubble",
        instruction: """
        Tell me exactly what to say next, in my voice, given where the conversation is right \
        now: one sentence I can say out loud, two at most. Nothing else.
        """,
        kind: .say)

    public static let whatToAsk = QuickAction(
        id: "ask", title: "What to ask", symbol: "questionmark.bubble",
        instruction: """
        Give me the single best question to ask next to move the conversation forward. One \
        line, nothing else.
        """,
        kind: .ask)

    public static let catchUp = QuickAction(
        id: "recap", title: "Catch me up", symbol: "arrow.counterclockwise",
        instruction: """
        Catch me up in at most three short bullets: what was discussed, decided, and still \
        open. Weight the last few minutes most.
        """,
        kind: .recap)

    public static let all = [answer, whatToSay, whatToAsk, catchUp]
}

extension Playbook {

    public static let generalID = "builtin.general"
    public static let pairingID = "builtin.pairing"

    /// The eight playbooks Saaa ships with. Users duplicate and edit them.
    public static let builtIns: [Playbook] = [
        general, sales, customerSuccess, recruiting, investor, standup, pairProgramming, oneOnOne, learning,
    ]

    public static let general = Playbook(
        id: generalID, name: "General", symbol: "sparkles", tint: .tide,
        tagline: "Any conversation",
        instructions: """
        Help me follow and contribute to this conversation. Keep answers faithful to what was \
        said. When I need facts that were not discussed, give your best knowledge and flag \
        uncertainty in a few words.
        """,
        quickActions: StandardActions.all,
        isBuiltIn: true)

    public static let sales = Playbook(
        id: "builtin.sales", name: "Sales", symbol: "chart.line.uptrend.xyaxis", tint: .green,
        tagline: "Discovery, demos, negotiation",
        instructions: """
        I'm the seller on this call. Help me run great discovery: uncover the pain, its business \
        impact, the decision process, budget and timeline. When they raise an objection, help me \
        acknowledge it, ask one clarifying question, then answer with evidence. Never invent \
        product capabilities, prices, discounts or customer names. Use my notes and knowledge for \
        facts, and say "worth checking" when something isn't covered.
        """,
        quickActions: [
            StandardActions.answer,
            QuickAction(
                id: "sales.discovery", title: "Discovery question", symbol: "magnifyingglass",
                instruction: """
                Give me the single best discovery question to ask next, given what we haven't \
                learned yet (pain, impact, decision process, budget, timeline). One line.
                """,
                kind: .ask),
            QuickAction(
                id: "sales.objection", title: "Handle objection", symbol: "shield.lefthalf.filled",
                instruction: """
                Give me a response to the objection they just raised that I can say out loud: \
                acknowledge it and answer with evidence from my notes or knowledge, in two \
                sentences at most.
                """,
                kind: .custom),
            StandardActions.whatToSay,
            StandardActions.catchUp,
        ],
        summarySections: ["Pain points", "Decision process", "Budget and timeline", "Objections and responses", "Next steps"],
        draftsFollowUpEmail: true, autoSuggest: true,
        titleKeywords: ["demo", "discovery", "intro", "sales", "pricing", "proposal", "prospect", "negotiation"],
        isBuiltIn: true)

    public static let customerSuccess = Playbook(
        id: "builtin.success", name: "Customer Success", symbol: "heart.text.square", tint: .rose,
        tagline: "Check-ins, renewals, escalations",
        instructions: """
        I own this customer relationship. Help me understand their goals and account health, \
        catch risk signals early (frustration, low usage, budget cuts, champion changes, \
        competitors), and respond with empathy and concrete next steps. Never promise features, \
        dates or credits that aren't in my notes.
        """,
        quickActions: [
            StandardActions.answer,
            QuickAction(
                id: "success.risk", title: "Probe for risk", symbol: "exclamationmark.shield",
                instruction: """
                Suggest one question that would surface hidden risk to this account (adoption, \
                budget, champion, competitors, unresolved issues), based on what was just said.
                """,
                kind: .ask),
            StandardActions.whatToSay,
            StandardActions.catchUp,
        ],
        summarySections: ["Customer goals", "Health and risks", "Requests", "Commitments we made"],
        draftsFollowUpEmail: true, autoSuggest: true,
        titleKeywords: ["qbr", "check-in", "checkin", "renewal", "onboarding", "escalation", "success", "kickoff", "kick-off"],
        isBuiltIn: true)

    public static let recruiting = Playbook(
        id: "builtin.recruiting", name: "Recruiting", symbol: "person.text.rectangle", tint: .violet,
        tagline: "Structured interviews, as the interviewer",
        instructions: """
        I'm interviewing a candidate. Help me run a fair, structured interview: suggest follow-ups \
        that ask for specifics (the situation, their own actions, measurable results), keep track \
        of which competencies have been covered, and point out when an answer stayed vague. Stay \
        neutral and job-related. Never suggest questions about age, family plans, health, \
        religion, nationality, or any other protected characteristic.
        """,
        quickActions: [
            QuickAction(
                id: "recruiting.next", title: "Next question", symbol: "arrow.right.circle",
                instruction: """
                Suggest the next interview question that best covers a competency we haven't \
                probed yet. One question, nothing else.
                """,
                kind: .ask),
            QuickAction(
                id: "recruiting.deeper", title: "Probe deeper", symbol: "arrow.down.right.circle",
                instruction: """
                Based on the candidate's last answer, suggest one follow-up that asks for \
                specifics: the situation, exactly what they did, and the measurable result.
                """,
                kind: .ask),
            QuickAction(
                id: "recruiting.coverage", title: "Coverage check", symbol: "checklist",
                instruction: """
                List which competencies and topics have been covered so far and which haven't, \
                in two short lists.
                """,
                kind: .recap),
            StandardActions.catchUp,
        ],
        summarySections: ["Strengths", "Concerns", "Evidence by competency", "Open questions for the debrief"],
        titleKeywords: ["interview", "screen", "screening", "onsite", "hiring", "candidate", "panel"],
        screenLens: .interviewer,
        isBuiltIn: true)

    public static let investor = Playbook(
        id: "builtin.investor", name: "Investor pitch", symbol: "building.columns", tint: .amber,
        tagline: "Fundraising conversations",
        instructions: """
        I'm the founder pitching investors. Help me answer crisply with the numbers in my notes \
        (traction, revenue, growth, burn, runway, market), handle tough questions honestly, and \
        notice what this investor cares about. If a number isn't in my notes, never make one up: \
        suggest how to answer without it.
        """,
        quickActions: [
            StandardActions.answer,
            QuickAction(
                id: "investor.numbers", title: "Back it with numbers", symbol: "number",
                instruction: """
                Answer their latest question in one or two sentences I can say, using concrete \
                numbers from my notes and knowledge. If the numbers aren't there, tell me what to \
                say instead without inventing any.
                """,
                kind: .answer),
            QuickAction(
                id: "investor.ask", title: "Ask them", symbol: "questionmark.bubble",
                instruction: """
                Give me the sharpest question to ask this investor next (their thesis, process, \
                portfolio fit, decision timeline). One line.
                """,
                kind: .ask),
            StandardActions.catchUp,
        ],
        summarySections: ["What they care about", "Concerns raised", "Asks and next steps"],
        draftsFollowUpEmail: true, autoSuggest: true,
        titleKeywords: ["investor", "vc", "pitch", "fundraise", "fundraising", "partner meeting", "seed", "series"],
        isBuiltIn: true)

    public static let standup = Playbook(
        id: "builtin.standup", name: "Standup", symbol: "person.3", tint: .sky,
        tagline: "Team syncs and planning",
        instructions: """
        Help me keep track of updates, blockers and owners in this team sync. Keep every \
        answer terse.
        """,
        quickActions: [
            QuickAction(
                id: "standup.update", title: "My update", symbol: "person.wave.2",
                instruction: """
                Draft my update from what I've said so far and my notes: done, next, blockers. \
                Three short lines.
                """,
                kind: .say),
            QuickAction(
                id: "standup.blockers", title: "Blockers", symbol: "hand.raised",
                instruction: "List the blockers mentioned so far and who raised each one.",
                kind: .recap),
            QuickAction(
                id: "standup.owners", title: "Who owns what", symbol: "person.crop.rectangle.stack",
                instruction: "List every action item mentioned so far with its owner.",
                kind: .recap),
            StandardActions.catchUp,
        ],
        summarySections: ["Updates by person", "Blockers"],
        titleKeywords: ["standup", "stand-up", "sync", "daily", "scrum", "weekly", "planning", "retro"],
        isBuiltIn: true)

    public static let pairProgramming = Playbook(
        id: pairingID, name: "Pair programming", symbol: "chevron.left.forwardslash.chevron.right", tint: .sky,
        tagline: "Coding together on a call",
        instructions: """
        I'm working through code with a colleague on a call, often with a screen shared. Help us \
        understand the code under discussion, spot bugs and edge cases, and choose the next step. \
        Prefer small, safe changes and say how to check them. When we're stuck, suggest what to \
        try or where to look next.
        """,
        quickActions: [
            QuickAction(
                id: "pairing.next", title: "Next step", symbol: "arrow.right.circle",
                instruction: "Suggest the single most useful next step for what we're working on, in one or two sentences.",
                kind: .say),
            QuickAction(
                id: "pairing.edges", title: "Edge cases", symbol: "exclamationmark.triangle",
                instruction: "List up to three edge cases or risks in what we're discussing that nobody has covered yet, as short bullets.",
                kind: .custom),
            QuickAction(
                id: "pairing.explain", title: "Explain it", symbol: "text.magnifyingglass",
                instruction: "Explain the thing we're stuck on in plain words, in at most three short bullets.",
                kind: .custom),
            StandardActions.catchUp,
        ],
        summarySections: ["Changes discussed", "Bugs found", "Follow-ups"],
        titleKeywords: ["pairing", "pair programming", "code review", "debugging", "mob", "walkthrough"],
        screenLens: .pairProgramming,
        isBuiltIn: true)

    public static let oneOnOne = Playbook(
        id: "builtin.oneonone", name: "1:1", symbol: "person.2", tint: .slate,
        tagline: "Manager and peer 1:1s",
        instructions: """
        This is a 1:1. Help me listen well, ask thoughtful open questions, give clear and kind \
        feedback, and capture what each of us committed to.
        """,
        quickActions: [
            StandardActions.answer,
            StandardActions.whatToAsk,
            QuickAction(
                id: "oneonone.reframe", title: "Say it kindly", symbol: "heart.circle",
                instruction: """
                Help me say what I need to say right now clearly, kindly and directly. One or \
                two sentences.
                """,
                kind: .say),
            StandardActions.catchUp,
        ],
        summarySections: ["Topics", "Feedback", "Commitments"],
        titleKeywords: ["1:1", "1-1", "1on1", "one on one", "one-on-one", "catch up", "catchup"],
        isBuiltIn: true)

    public static let learning = Playbook(
        id: "builtin.learning", name: "Lecture", symbol: "graduationcap", tint: .ember,
        tagline: "Classes, talks and webinars",
        instructions: """
        I'm here to learn. Explain concepts simply when I ask, define jargon, connect ideas to \
        what was said earlier, and help me ask good questions.
        """,
        quickActions: [
            QuickAction(
                id: "learning.explain", title: "Explain that", symbol: "lightbulb",
                instruction: """
                Explain the concept being discussed right now simply, in two sentences with one \
                concrete example.
                """,
                kind: .answer),
            QuickAction(
                id: "learning.define", title: "Define terms", symbol: "character.book.closed",
                instruction: "Define the jargon and acronyms used in the last few minutes, one line each.",
                kind: .custom),
            QuickAction(
                id: "learning.question", title: "Question to ask", symbol: "hand.raised",
                instruction: "Suggest one insightful question I could ask the speaker about what was just covered.",
                kind: .ask),
            StandardActions.catchUp,
        ],
        summarySections: ["Key concepts", "Definitions", "Things to review"],
        titleKeywords: ["lecture", "class", "webinar", "talk", "seminar", "course", "workshop", "training"],
        isBuiltIn: true)
}
