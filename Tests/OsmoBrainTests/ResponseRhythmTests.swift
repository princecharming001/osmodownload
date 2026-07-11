import Testing
import Foundation
@testable import OsmoBrain

@Suite("Response rhythm — tempo, deliberation, silence vs their own baseline")
struct ResponseRhythmTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    func turn(_ fromMe: Bool, _ text: String, _ d: Date, read: Date? = nil) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: text, sentAt: d, readAt: read)
    }

    @Test("Below the sample floor, everything is nil and isEmpty is true")
    func insufficient() {
        let now = at(day: 20)
        let turns = [turn(true, "hey", at(day: 1)), turn(false, "hi", at(day: 1, hour: 13))]
        let r = ResponseRhythm.read(turns, now: now)
        #expect(r.isEmpty)
        #expect(r.replyGapMedian == nil)
        #expect(r.replyGapP25 == nil)
        #expect(r.replyGapP75 == nil)
    }

    @Test("Reply-gap percentiles are ordered p25 <= median <= p75")
    func percentilesOrdered() {
        var turns: [ThreadTurn] = []
        // 5 exchanges with reply gaps of 1h, 2h, 3h, 4h, 5h.
        for (i, hrs) in [1, 2, 3, 4, 5].enumerated() {
            let base = at(day: 2 + i, hour: 9)
            turns.append(turn(true, "q", base))
            turns.append(turn(false, "a", base.addingTimeInterval(Double(hrs) * 3600)))
        }
        let r = ResponseRhythm.read(turns, now: at(day: 20))
        #expect(!r.isEmpty)
        #expect(r.sampleCount == 5)
        let p25 = r.replyGapP25!, med = r.replyGapMedian!, p75 = r.replyGapP75!
        #expect(p25 <= med)
        #expect(med <= p75)
    }

    @Test("Read receipts split into deliberation (send→read) and attention (read→reply)")
    func deliberationVsNeglect() {
        var turns: [ThreadTurn] = []
        // My message read 30min later, replied 2h after reading, x3.
        for i in 0..<3 {
            let base = at(day: 2 + i, hour: 9)
            let read = base.addingTimeInterval(1800)
            turns.append(turn(true, "q", base, read: read))
            turns.append(turn(false, "a", read.addingTimeInterval(7200)))
        }
        let r = ResponseRhythm.read(turns, now: at(day: 20))
        #expect(r.sendToReadMedian == 1800)
        #expect(r.readToReplyMedian == 7200)
    }

    @Test("A slow-but-consistent replier at their normal cadence reads as normal silence")
    func slowReplierIsNormal() {
        var turns: [ThreadTurn] = []
        // They always take ~2 days to reply.
        for i in 0..<5 {
            let base = at(day: 1 + i * 3, hour: 9)
            turns.append(turn(true, "q", base))
            turns.append(turn(false, "a", base.addingTimeInterval(2 * 86_400)))
        }
        let r = ResponseRhythm.read(turns, now: at(day: 20))
        let lastMsg = at(day: 13 + 2, hour: 9)  // their last reply timestamp-ish
        // 1 day since last message is well within their 2-day p75 → normal.
        let s = r.silence(sinceLastMessageAt: lastMsg, now: lastMsg.addingTimeInterval(86_400))
        #expect(s == .normal)
    }

    @Test("A gap well past their own p75 reads as unusual")
    func unusualSilence() {
        var turns: [ThreadTurn] = []
        // Fast replier: ~1h each time.
        for i in 0..<5 {
            let base = at(day: 2 + i, hour: 9)
            turns.append(turn(true, "q", base))
            turns.append(turn(false, "a", base.addingTimeInterval(3600)))
        }
        let r = ResponseRhythm.read(turns, now: at(day: 20))
        let last = at(day: 6, hour: 10)
        // 5 days of silence from someone who normally replies in an hour → unusual.
        let s = r.silence(sinceLastMessageAt: last, now: last.addingTimeInterval(5 * 86_400))
        #expect(s == .unusual)
    }
}
