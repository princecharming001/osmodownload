import Testing
import Foundation
import OsmoCore
@testable import OsmoBrain

@Suite("OsmoBrain — registers, goals, moves")
struct ClassificationTests {

    @Test("Relationship register inference across the spectrum")
    func registers() {
        #expect(RelationshipRegister.infer(from: "my boss") == .boss)
        #expect(RelationshipRegister.infer(from: "girlfriend") == .partner)
        #expect(RelationshipRegister.infer(from: "gf") == .partner)
        #expect(RelationshipRegister.infer(from: "a VC I'm raising from") == .investor)
        #expect(RelationshipRegister.infer(from: "my best friend from college") == .bestFriend)
        #expect(RelationshipRegister.infer(from: "the recruiter at Stripe") == .recruiter)
        #expect(RelationshipRegister.infer(from: "situationship") == .situationship)
        #expect(RelationshipRegister.infer(from: "my mom") == .parent)
        #expect(RelationshipRegister.infer(from: "some rando") == .unknown)
    }

    @Test("Register formality ordering is sane")
    func formality() {
        #expect(RelationshipRegister.investor.formality > RelationshipRegister.coworker.formality)
        #expect(RelationshipRegister.coworker.formality > RelationshipRegister.partner.formality)
        #expect(!RelationshipRegister.boss.emojiNaturalByDefault)
        #expect(RelationshipRegister.bestFriend.emojiNaturalByDefault)
    }

    @Test("Goal classification maps free text to a kind")
    func goals() {
        #expect(GoalKind.classify("close the deal by end of quarter") == .closeDeal)
        #expect(GoalKind.classify("negotiate a higher salary") == .negotiate)
        #expect(GoalKind.classify("rebuild trust with my dad") == .rebuildTrust)
        #expect(GoalKind.classify("get a second date") == .getDate)
        #expect(GoalKind.classify("reconnect, we haven't talked in months") == .reconnect)
        #expect(GoalKind.classify("get them on a call") == .getMeeting)
        #expect(GoalKind.classify(nil) == .freeform)
    }

    @Test("Move classification, incl. the negotiation/deescalation moves a keyboard app lacked")
    func moves() {
        #expect(Move.classify("apologize for missing dinner") == .apologize)
        #expect(Move.classify("push back on their price") == .negotiate)
        #expect(Move.classify("calm things down after the fight") == .deescalate)
        #expect(Move.classify("say no to the weekend trip") == .decline)
        #expect(Move.classify("comfort her, her dog died") == .comfort)
        #expect(Move.classify("find a time to meet") == .scheduleTime)
        #expect(Move.classify("just say hi") == .plain)
    }
}

@Suite("OsmoBrain — thread read (LSM + momentum)")
struct ThreadReadTests {

    @Test("Reads whose turn it is + their message features")
    func read() {
        let turns = [
            ThreadTurn(fromMe: true, text: "how did the interview go"),
            ThreadTurn(fromMe: false, text: "honestly no idea, they said they'd call friday??")
        ]
        let r = ThreadRead.read(turns)
        #expect(r.ball == .theirs)
        #expect(r.asksQuestion)
        #expect(r.hasOpenQuestion)
        #expect(r.mostlyLowercase)
        #expect(r.theirLastText?.contains("friday") == true)
    }

    @Test("Detects the user carrying a thread that went quiet")
    func carrying() {
        let turns = [
            ThreadTurn(fromMe: false, text: "yeah for sure"),
            ThreadTurn(fromMe: true, text: "so are we still on for saturday?"),
            ThreadTurn(fromMe: true, text: "no rush just lmk")
        ]
        let r = ThreadRead.read(turns)
        #expect(r.ball == .mine)
        #expect(r.userCarrying)
    }

    @Test("Idle time computed from timestamps")
    func idle() {
        let now = Date(timeIntervalSince1970: 10_000)
        let turns = [ThreadTurn(fromMe: false, text: "hey", sentAt: Date(timeIntervalSince1970: 6_400))]
        let r = ThreadRead.read(turns, now: now)
        #expect(r.idle == 3_600)
    }
}

@Suite("OsmoBrain — strategy selection (the psychology judgment)")
struct StrategyTests {

    private func plan(move: Move, goal: GoalKind, reg: RelationshipRegister,
                      read: ThreadRead = .read([])) -> StrategyPlan {
        Strategy.plan(move: move, goalKind: goal, register: reg, read: read)
    }

    private func ids(_ p: StrategyPlan) -> [String] { p.techniques.map(\.id) }

    @Test("Apology to a partner uses the clean-apology + repair techniques")
    func apologyPartner() {
        let p = plan(move: .apologize, goal: .rebuildTrust, reg: .partner)
        #expect(ids(p).contains("own-it-apology"))
        #expect(ids(p).contains("repair-attempt") || ids(p).contains("turn-toward-bid"))
    }

    @Test("Negotiating with a client uses labeling + calibrated questions")
    func negotiateClient() {
        let p = plan(move: .negotiate, goal: .negotiate, reg: .client)
        #expect(ids(p).contains("labeling"))
        #expect(ids(p).contains("calibrated-question"))
    }

    @Test("A their-open-question always gets answered first")
    func answersFirst() {
        let read = ThreadRead.read([ThreadTurn(fromMe: false, text: "wait are you free thursday?")])
        let p = plan(move: .answer, goal: .freeform, reg: .friend, read: read)
        #expect(p.techniques.first?.id == "answer-first")
    }

    @Test("High-formality register suppresses warm relationship techniques (unless repairing)")
    func registerFilter() {
        // A plain ask to an investor should not carry Gottman warmth techniques.
        let p = plan(move: .ask, goal: .professionalAsk, reg: .investor)
        #expect(!p.techniques.contains { $0.family == .relationship })
        #expect(p.techniques.contains { $0.id == "reciprocity" || $0.id == "one-clear-ask" })
    }

    @Test("Technique list is capped and de-duplicated")
    func capped() {
        let p = plan(move: .negotiate, goal: .closeDeal, reg: .client,
                     read: ThreadRead.read([ThreadTurn(fromMe: false, text: "not sure about the price")]))
        #expect(p.techniques.count <= Strategy.cap)
        #expect(Set(ids(p)).count == p.techniques.count)   // no dupes
    }
}

@Suite("OsmoBrain — end-to-end plan + prompt + parse")
struct EngineTests {

    @Test("plan() composes a cacheable core + a grounded volatile turn")
    func compose() {
        let ctx = SuggestionContext(
            relationshipLabel: "my girlfriend", platform: .imessage,
            goalText: "rebuild trust after I flaked", toneHint: "sincere, not groveling",
            boundaries: ["don't bring up her ex"],
            selfContext: "I'm bad at apologies and tend to over-explain",
            relationshipMemory: "Lately: she's been stressed about work.",
            transcript: [ThreadTurn(fromMe: false, text: "i just felt like you didnt care tbh")],
            userIntent: "apologize for bailing last night")
        let brain = OsmoBrain()
        let p = brain.plan(ctx)

        // Cacheable core is stable + carries the anti-tell + 3-take contract.
        #expect(p.prompt.systemCore == PromptComposer.systemCore)
        #expect(p.prompt.systemCore.contains("em-dash"))
        #expect(p.prompt.systemCore.contains("three takes"))
        // Volatile turn is grounded in everything we know.
        let turn = p.prompt.userTurn
        #expect(turn.contains("girlfriend"))
        #expect(turn.contains("rebuild trust after I flaked"))
        #expect(turn.contains("don't bring up her ex"))
        #expect(turn.contains("didnt care"))            // the real message
        #expect(turn.contains("mirror it"))             // LSM: lowercase mirror
        #expect(turn.lowercased().contains("apolog"))   // the move
        // Chose the apology psychology.
        #expect(p.strategy.techniques.contains { $0.id == "own-it-apology" })
        #expect(p.safety == .allow)
    }

    @Test("parse() yields three labeled takes with a why on the lead")
    func parse() {
        let ctx = SuggestionContext(relationshipLabel: "coworker", platform: .slack,
                                    userIntent: "follow up on the doc")
        let brain = OsmoBrain()
        let p = brain.plan(ctx)
        let raw = """
        1. hey, any chance you got to that doc?
        2. no rush at all, just circling back on the doc when you have a sec
        3. the doc misses you 🥲 lmk when you're free
        """
        let set = brain.parse(raw, plan: p)
        #expect(set.takes.count == 3)
        #expect(set.takes[0].slant == .direct)
        #expect(set.takes[0].text == "hey, any chance you got to that doc?")   // numbering stripped
        #expect(set.takes[1].slant == .warmer)
        #expect(set.takes[2].slant == .lighter)
        #expect(set.takes[0].whyItWorks != nil)          // lead technique rationale attached
    }

    @Test("Safety refuses manipulation, allows genuine persuasion")
    func safety() {
        let brain = OsmoBrain()
        let bad = brain.plan(SuggestionContext(relationshipLabel: "crush", platform: .imessage,
                                               goalText: "guilt trip them into seeing me"))
        if case .refuse = bad.safety {} else { Issue.record("should refuse manipulation") }
        let ok = brain.plan(SuggestionContext(relationshipLabel: "client", platform: .gmail,
                                              goalText: "make the case for our proposal"))
        #expect(ok.safety == .allow)
    }
}
