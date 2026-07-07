import Testing
import Foundation
@testable import OsmoBrain

@Suite("Partner profile — the read on the other person")
struct PartnerProfileTests {
    func turn(_ fromMe: Bool, _ text: String, at: Date? = nil) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: text, sentAt: at)
    }

    @Test("Too few of THEIR messages → empty read (never guess)")
    func tooFew() {
        let p = PartnerProfile.read([turn(false, "hey"), turn(true, "hi"), turn(true, "you there?")])
        #expect(p.isEmpty)
        #expect(p.chips.isEmpty)
        #expect(p.tonality == nil)
        #expect(p.directives.isEmpty)
    }

    @Test("Casual lowercase brief texter reads casual + brief")
    func casualBrief() {
        let p = PartnerProfile.read([
            turn(false, "lol yea"),
            turn(false, "nah im good bro"),
            turn(false, "wanna pull up later"),
            turn(true, "Sure, what time works?"),
        ])
        #expect(!p.isEmpty)
        #expect(p.formality < 0.35)
        #expect(p.chips.contains("Casual"))
        #expect(p.chips.contains("Brief texter"))
        #expect(p.tonality?.contains("casual") == true)
        // My formal message must not pollute THEIR read.
        #expect(p.lowercaseShare > 0.9)
    }

    @Test("Formal correspondent reads polished")
    func formal() {
        let p = PartnerProfile.read([
            turn(false, "Good morning — thank you for the update on the proposal."),
            turn(false, "I would appreciate your thoughts on the revised terms. Best, Dana"),
            turn(false, "Hello Anish, please find the agenda attached for Thursday."),
        ])
        #expect(p.formality > 0.65)
        #expect(p.chips.contains("Formal"))
        #expect(p.directives.contains { $0.contains("polish") })
    }

    @Test("Reply tempo: median gap from my message to their reply")
    func replyTempo() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var turns: [ThreadTurn] = []
        // Three exchanges where they reply in 10min, 20min, 30min → median 20min.
        for (i, gap) in [600.0, 1200.0, 1800.0].enumerated() {
            let base = t0.addingTimeInterval(Double(i) * 86_400)
            turns.append(turn(true, "ping \(i)", at: base))
            turns.append(turn(false, "pong \(i) here we go", at: base.addingTimeInterval(gap)))
        }
        let p = PartnerProfile.read(turns)
        #expect(p.medianReplySeconds == 1200)
        #expect(p.chips.contains("Replies within hours") || p.chips.contains("Replies fast"))
    }

    @Test("Active block only claimed when it dominates")
    func activeBlock() {
        let cal = Calendar.current
        func at(hour: Int, day: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
        }
        // 6 evening messages, 1 morning → evenings dominates.
        var turns = (1...6).map { turn(false, "msg \($0) yeah ok", at: at(hour: 20, day: $0)) }
        turns.append(turn(false, "early one", at: at(hour: 8, day: 7)))
        let p = PartnerProfile.read(turns)
        #expect(p.activeBlock == "evenings")
        // Evenly spread → no claim.
        let spread = [8, 13, 20, 2, 9, 14].enumerated().map {
            turn(false, "m\($0.offset) hello there", at: at(hour: $0.element, day: $0.offset + 1))
        }
        #expect(PartnerProfile.read(spread).activeBlock == nil)
    }

    @Test("Directives calibrate emoji + length to them")
    func directives() {
        let p = PartnerProfile.read([
            turn(false, "omg yes 😂 love it"),
            turn(false, "so good 🥳 cant wait"),
            turn(false, "haha totally 😄"),
        ])
        #expect(p.directives.contains { $0.contains("emoji freely") })
        #expect(p.tonality?.contains("warm") == true)
    }
}
