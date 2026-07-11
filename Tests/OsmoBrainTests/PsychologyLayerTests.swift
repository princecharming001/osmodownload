import Testing
import Foundation
@testable import OsmoBrain

@Suite("Bids for connection — turn-toward + missed bids")
struct BidDetectorTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))! }
    func turn(_ fromMe: Bool, _ text: String, _ d: Date) -> ThreadTurn { ThreadTurn(fromMe: fromMe, text: text, sentAt: d) }

    @Test("A question / emotional share is a bid; filler is not")
    func classify() {
        #expect(BidDetector.bidType("how was your day?") == .question)
        #expect(BidDetector.bidType("i'm so nervous about the interview tomorrow") == .emotional)
        #expect(BidDetector.bidType("i just got back from the airport and my flight was delayed") == .sharing)
        #expect(BidDetector.bidType("lol") == nil)
        #expect(BidDetector.bidType("ok") == nil)
    }

    @Test("Turning toward every bid → high rate; ignoring them → low")
    func turnTowardRate() {
        var toward: [ThreadTurn] = []
        var away: [ThreadTurn] = []
        for i in 0..<6 {
            let base = at(day: 1 + i)
            toward.append(turn(false, "how did the big meeting go today?", base))
            toward.append(turn(true, "it went really well, thanks for asking! how are you?", base.addingTimeInterval(1800)))
            away.append(turn(false, "how did the big meeting go today?", base))
            away.append(turn(true, "ok", base.addingTimeInterval(1800)))   // filler = turned away
        }
        #expect((BidDetector.read(toward, now: at(day: 20)).turnTowardRate ?? 0) > 0.8)
        #expect((BidDetector.read(away, now: at(day: 20)).turnTowardRate ?? 1) < 0.2)
    }

    @Test("Their last message being an unanswered bid → lastBidMissed")
    func missedBid() {
        let turns = [turn(true, "hey", at(day: 1)), turn(false, "wait did you hear what happened with my sister??", at(day: 2))]
        let r = BidDetector.read(turns, now: at(day: 3))
        #expect(r.lastWasBid)
        #expect(r.lastBidMissed)
        #expect(r.lastBidType == .question)
    }

    @Test("Below the sample floor, turnTowardRate is nil")
    func floor() {
        let turns = [turn(false, "how are you?", at(day: 1)), turn(true, "good thanks how are you", at(day: 1, hour: 13))]
        #expect(BidDetector.read(turns, now: at(day: 3)).turnTowardRate == nil)
    }
}

@Suite("Relational style — pursue/withdraw + space vs reassurance")
struct RelationalStyleTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))! }
    func turn(_ fromMe: Bool, _ text: String, _ d: Date) -> ThreadTurn { ThreadTurn(fromMe: fromMe, text: text, sentAt: d) }

    @Test("They re-initiate after silences and reply fast → pursues + needs reassurance")
    func pursues() {
        var turns: [ThreadTurn] = []
        // Every conversation opener (after an >8h gap) is THEIRS, and they reply fast.
        for i in 0..<6 {
            let base = at(day: 1 + i * 2, hour: 9)   // each opener a new day (>8h gap)
            turns.append(turn(false, "morning! thinking of you", base))
            turns.append(turn(true, "aw hi", base.addingTimeInterval(1800)))
            turns.append(turn(false, "how's your day going?", base.addingTimeInterval(2400)))
            turns.append(turn(true, "good! busy", base.addingTimeInterval(3000)))
        }
        let s = RelationalStyle.read(turns, now: at(day: 30))
        #expect(s.tendency == .pursues)
        #expect(s.spaceNeed == .reassurance)
    }

    @Test("The user carries initiation, they never re-open → withdraws + needs space")
    func withdraws() {
        var turns: [ThreadTurn] = []
        // 4-day spacing so their same-cycle reply can't collide with the next opener;
        // every conversation is opened by ME, they only ever respond.
        for i in 0..<6 {
            let base = at(day: 1 + i * 4, hour: 9)
            turns.append(turn(true, "hey! how have you been?", base))                       // I open every time
            turns.append(turn(false, "hey sorry been busy, good though", base.addingTimeInterval(2 * 3600)))  // reply, same convo
        }
        let s = RelationalStyle.read(turns, now: at(day: 30))
        #expect(s.tendency == .withdraws)
        #expect(s.spaceNeed == .space)
    }

    @Test("Thin history → unknown, no fabricated read")
    func thin() {
        let s = RelationalStyle.read([turn(false, "hi", at(day: 1))], now: at(day: 2))
        #expect(s.tendency == .unknown)
        #expect(s.note == nil)
    }
}
