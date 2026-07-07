import Testing
import Foundation
@testable import OsmoBrain

@Suite("Reach-out verdict — nudge or lay back")
struct ReachOutVerdictTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    func turn(_ fromMe: Bool, _ text: String, _ d: Date) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: text, sentAt: d)
    }
    func verdict(_ turns: [ThreadTurn], now: Date) -> ReachOutVerdict {
        ReachOutVerdict.decide(read: ThreadRead.read(turns, now: now),
                               partner: PartnerProfile.read(turns), now: now)
    }

    @Test("They sent last → your turn, always")
    func yourTurn() {
        let now = at(day: 20, hour: 14)
        let v = verdict([turn(true, "hey", at(day: 19, hour: 10)),
                         turn(false, "hey! what's up", at(day: 19, hour: 11))], now: now)
        #expect(v.kind == .yourTurn)
    }

    @Test("Quiet inside their rhythm → give it space, with their tempo cited")
    func giveItSpace() {
        let now = at(day: 20, hour: 14)
        var turns: [ThreadTurn] = []
        // They reply in ~1 day, consistently.
        for d in [2, 5, 8] {
            turns.append(turn(true, "ping", at(day: d, hour: 10)))
            turns.append(turn(false, "pong, sounds good", at(day: d + 1, hour: 10)))
        }
        turns.append(turn(true, "one more thing", at(day: 20, hour: 2)))   // 12h ago
        let v = verdict(turns, now: now)
        #expect(v.kind == .giveItSpace)
        #expect(v.detail?.contains("1d") == true)
    }

    @Test("Well past their rhythm → worth a nudge")
    func worthANudge() {
        let now = at(day: 20, hour: 14)
        var turns: [ThreadTurn] = []
        // They reply in ~4h.
        for d in [2, 4, 6] {
            turns.append(turn(true, "ping", at(day: d, hour: 10)))
            turns.append(turn(false, "pong ok", at(day: d, hour: 14)))
        }
        turns.append(turn(true, "thoughts?", at(day: 18, hour: 14)))   // 2 days ago
        let v = verdict(turns, now: now)
        #expect(v.kind == .goodTime)
        #expect(v.headline == "Worth a nudge")
    }

    @Test("Double-texted and not yet nudge-time → lay back")
    func layBack() {
        let now = at(day: 20, hour: 14)
        var turns: [ThreadTurn] = []
        for d in [2, 5, 8] {
            turns.append(turn(true, "ping", at(day: d, hour: 10)))
            turns.append(turn(false, "pong sounds good", at(day: d + 1, hour: 10)))
        }
        turns.append(turn(true, "hey!", at(day: 20, hour: 1)))
        turns.append(turn(true, "also — free thursday?", at(day: 20, hour: 3)))
        let v = verdict(turns, now: now)
        #expect(v.kind == .layBack)
    }

    @Test("Empty thread → say hi")
    func sayHi() {
        let v = verdict([], now: at(day: 20, hour: 14))
        #expect(v.kind == .sayHi)
    }
}

@Suite("Trajectory — warming, steady, cooling")
struct TrajectoryTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int, month: Int = 6) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func turn(_ fromMe: Bool, _ d: Date) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: "hey there friend", sentAt: d)
    }

    @Test("Too little history → insufficient, no claims")
    func insufficient() {
        let now = at(day: 25, hour: 12)
        let turns = (1...4).map { turn(false, at(day: $0 + 10, hour: 12)) }
        #expect(Trajectory.read(turns, now: now).kind == .insufficient)
    }

    @Test("Their frequency dropping reads as cooling with the honest driver")
    func cooling() {
        let now = at(day: 28, hour: 12)
        var turns: [ThreadTurn] = []
        // Baseline (April 3 – June 14): ~3 of their messages/week (steady flow).
        for i in 0..<24 { turns.append(turn(false, at(day: 3 + i * 3, hour: 10, month: 4))) }
        // Recent 2 weeks (June 14–28): they message ~3 times TOTAL (~1.1/wk).
        turns.append(turn(false, at(day: 16, hour: 10)))
        turns.append(turn(false, at(day: 21, hour: 10)))
        turns.append(turn(false, at(day: 26, hour: 10)))
        let t = Trajectory.read(turns, now: now)
        #expect(t.kind == .cooling)
        #expect(t.driver?.contains("dropped off") == true)
    }

    @Test("Their frequency rising reads as warming")
    func warming() {
        let now = at(day: 28, hour: 12)
        var turns: [ThreadTurn] = []
        // Baseline: ~1/week (8 across 8 weeks, April 20 – June 14).
        for i in 0..<8 { turns.append(turn(false, at(day: 20 + i * 7, hour: 10, month: 4))) }
        // Recent 2 weeks: 8 of their messages (~4/wk).
        for i in 0..<8 { turns.append(turn(false, at(day: 15 + i, hour: 10))) }
        let t = Trajectory.read(turns, now: now)
        #expect(t.kind == .warming)
        #expect(t.driver != nil)
    }

    @Test("Stable cadence reads steady, no driver")
    func steady() {
        let now = at(day: 28, hour: 12)
        var turns: [ThreadTurn] = []
        // ~2/week in both windows (April 3 onward, every ~3.5 days).
        for i in 0..<24 { turns.append(turn(false, at(day: 3 + i * 3, hour: 10, month: 4).addingTimeInterval(Double(i % 2) * 43_200)) ) }
        // Recent: continue the same cadence June 15/18/21/24/27.
        for d in [15, 18, 21, 24, 27] { turns.append(turn(false, at(day: d, hour: 10))) }
        let t = Trajectory.read(turns, now: now)
        #expect(t.kind == .steady)
        #expect(t.driver == nil)
    }
}

@Suite("Tone check — the overthink stopper")
struct ToneCheckTests {
    func partner(_ texts: [String]) -> PartnerProfile {
        PartnerProfile.read(texts.map { ThreadTurn(fromMe: false, text: $0) })
    }
    let calmRead = ThreadRead.read([ThreadTurn(fromMe: false, text: "sounds good, keep me posted")])

    @Test("A normal message gets the reassurance verdict, zero flags")
    func clean() {
        let c = ToneCheck.check(draft: "yeah 7 works — see you there",
                                partner: partner(["ok cool", "see u", "yeah lets do it"]),
                                read: calmRead)
        #expect(c.flags.isEmpty)
        #expect(c.verdict == "This lands fine — send it.")
        #expect(c.sendable)
    }

    @Test("Wall of text to a brief texter gets the length flag")
    func tooLong() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let c = ToneCheck.check(draft: long,
                                partner: partner(["ok", "lol yeah", "cool cool"]),
                                read: calmRead)
        #expect(c.flags.contains { $0.title.contains("Longer than") })
    }

    @Test("Chasing while already carrying the thread is the big flag")
    func chasing() {
        let carrying = ThreadRead.read([
            ThreadTurn(fromMe: true, text: "hey"), ThreadTurn(fromMe: true, text: "you around?"),
        ])
        let c = ToneCheck.check(draft: "just checking in again, let me know",
                                partner: partner(["yeah", "ok", "sure thing"]),
                                read: carrying)
        #expect(c.flags.contains { $0.title == "Reads like chasing" })
        #expect(c.flags.first { $0.title == "Reads like chasing" }?.detail.contains("last word") == true)
    }

    @Test("Question pile-up + sorry overload + hedging all flag")
    func anxietyStack() {
        let c = ToneCheck.check(
            draft: "sorry to bother you, sorry! just wondering — are you free? did you see my text? should I book it? no worries if not, if that makes sense, maybe kind of",
            partner: partner(["yeah", "sure", "sounds good man"]),
            read: calmRead)
        #expect(c.flags.contains { $0.title.contains("questions at once") })
        #expect(c.flags.contains { $0.title.contains("sorries") })
        #expect(c.flags.contains { $0.title == "Hedging stacks up" })
        #expect(!c.sendable)
        #expect(c.verdict == "Worth a quick second pass.")
    }

    @Test("Formality mismatch flags only against a casual partner")
    func registerMismatch() {
        let casual = partner(["lol yeah bro", "nah im good", "wanna pull up"])
        let c = ToneCheck.check(draft: "Dear Alex, I hope this finds you well. Regards, A.",
                                partner: casual, read: calmRead)
        #expect(c.flags.contains { $0.title.contains("More formal") })
        let formal = partner(["Good morning — thank you for the update.",
                              "I would appreciate your thoughts.",
                              "Hello Anish, please find the agenda attached."])
        let c2 = ToneCheck.check(draft: "Dear Alex, I hope this finds you well. Regards, A.",
                                 partner: formal, read: calmRead)
        #expect(!c2.flags.contains { $0.title.contains("More formal") })
    }

    @Test("One flag still reads as sendable — reassurance bias")
    func oneFlagSendable() {
        let c = ToneCheck.check(draft: "so excited!!! this is great!!! can't wait!!!",
                                partner: partner(["nice", "great stuff", "love it"]),
                                read: calmRead)
        #expect(c.flags.count == 1)
        #expect(c.sendable)
        #expect(c.verdict == "Nearly there — one small thing.")
    }
}
