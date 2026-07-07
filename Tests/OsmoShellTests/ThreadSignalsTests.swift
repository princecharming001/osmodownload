import Testing
import Foundation
@testable import OsmoShell

@Suite("DeadlineDetector — deterministic deadline phrase → concrete Date")
struct DeadlineDetectorTests {
    private func now(hour: Int = 12, weekday: Int? = nil) -> Date {
        // A fixed, known Wednesday (2026-06-03) so weekday math is stable.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 3; comps.hour = hour; comps.minute = 0
        return Calendar.current.date(from: comps)!
    }

    @Test("tonight resolves to today at 8pm")
    func tonight() {
        let n = now(hour: 10)
        let hit = DeadlineDetector.detect("wanna do dinner tonight?", now: n)
        #expect(hit != nil)
        #expect(hit?.due != nil)
        #expect(Calendar.current.isDate(hit!.due!, inSameDayAs: n))
        #expect(Calendar.current.component(.hour, from: hit!.due!) == 20)
    }

    @Test("tomorrow resolves to the next calendar day")
    func tomorrow() {
        let n = now(hour: 15)
        let hit = DeadlineDetector.detect("let's talk tomorrow", now: n)
        let expectedDay = Calendar.current.date(byAdding: .day, value: 1, to: n)!
        #expect(Calendar.current.isDate(hit!.due!, inSameDayAs: expectedDay))
    }

    @Test("'by <weekday>' resolves to the next occurrence of that weekday")
    func byWeekday() {
        let n = now()   // Wednesday
        let hit = DeadlineDetector.detect("can you send it by friday", now: n)
        #expect(hit != nil)
        #expect(Calendar.current.component(.weekday, from: hit!.due!) == 6)   // Friday = 6
        #expect(hit!.due! > n)
    }

    @Test("'at N pm/am' resolves a concrete time, rolling to tomorrow if already past")
    func clockTime() {
        let n = now(hour: 14)   // 2pm
        let future = DeadlineDetector.detect("meet at 5pm", now: n)
        #expect(Calendar.current.component(.hour, from: future!.due!) == 17)
        #expect(Calendar.current.isDate(future!.due!, inSameDayAs: n))

        let past = DeadlineDetector.detect("call was at 9am", now: n)
        #expect(Calendar.current.component(.hour, from: past!.due!) == 9)
        // 9am already passed today (it's 2pm) — rolls to tomorrow.
        #expect(!Calendar.current.isDate(past!.due!, inSameDayAs: n))
    }

    @Test("Negative: ordinary text with no deadline phrase returns nil")
    func negativeNoDeadline() {
        #expect(DeadlineDetector.detect("bye for now, talk later", now: now()) == nil)
        #expect(DeadlineDetector.detect("that show was great", now: now()) == nil)
    }

    @Test("Explicit numeric date (month/day) resolves this year, or next if already past")
    func explicitDate() {
        let n = now()   // 2026-06-03
        let hit = DeadlineDetector.detect("let's do 7/9", now: n)
        #expect(hit != nil)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: hit!.due!)
        #expect(comps.month == 7 && comps.day == 9 && comps.year == 2026)
    }
}

@Suite("MoneyDetector")
struct MoneyDetectorTests {
    @Test("Dollar amounts and payment-app markers are detected")
    func detectsMoney() {
        #expect(MoneyDetector.detect("can you send me $45 for the tickets") != nil)
        #expect(MoneyDetector.detect("just venmo me whenever") != nil)
        #expect(MoneyDetector.detect("you still owe me for last time") != nil)
    }

    @Test("Ordinary text has no money mention")
    func noMoneyMention() {
        #expect(MoneyDetector.detect("see you at the party") == nil)
    }
}

@Suite("ThreadSignals — the deterministic half of a thread's intel")
struct ThreadSignalsTests {
    @Test("The last message being OURS means nothing is owed right now")
    func lastFromMeIsEmpty() {
        let intel = ThreadSignals.read(theirLastText: "ok see you then", lastFromMe: true, lastMessageAt: Date())
        #expect(intel == DeterministicIntel())
    }

    @Test("Money mention infers .pay action + thoughtful effort")
    func moneyInfersPay() {
        let intel = ThreadSignals.read(theirLastText: "can you venmo me $20 for the uber",
                                       lastFromMe: false, lastMessageAt: Date())
        #expect(intel.action == .pay)
        #expect(intel.effort == .thoughtful)
        #expect(intel.moneyMention != nil)
    }

    @Test("A timed deadline infers .schedule action + urgency by distance")
    func deadlineInfersSchedule() {
        let now = Date()
        let intel = ThreadSignals.read(theirLastText: "can we meet tonight?", lastFromMe: false,
                                       lastMessageAt: now, now: now)
        #expect(intel.action == .schedule)
        #expect(intel.urgency == .today)
        #expect(intel.deadline != nil)
    }

    @Test("Plain inbound with no deadline/money defaults to .reply, quick effort")
    func plainInboundIsReply() {
        let intel = ThreadSignals.read(theirLastText: "haha yeah", lastFromMe: false, lastMessageAt: Date())
        #expect(intel.action == .reply)
        #expect(intel.effort == .quick)
        #expect(intel.urgency == nil)
    }

    @Test("A question mark sets openQuestion")
    func questionMarkSetsFlag() {
        let intel = ThreadSignals.read(theirLastText: "are we still on for friday?",
                                       lastFromMe: false, lastMessageAt: Date())
        #expect(intel.openQuestion == true)
    }

    @Test("Long or multi-question messages are .thoughtful effort")
    func longMessageIsThoughtful() {
        let long = Array(repeating: "word", count: 35).joined(separator: " ")
        let intel = ThreadSignals.read(theirLastText: long, lastFromMe: false, lastMessageAt: Date())
        #expect(intel.effort == .thoughtful)
    }
}
