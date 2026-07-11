import Testing
import Foundation
@testable import OsmoBrain

@Suite("Effort balance — direction-aware, fires only when THEY under-invest")
struct EffortBalanceTests {
    let cal = Calendar.current
    func at(day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    func turn(_ fromMe: Bool, _ text: String, _ d: Date) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: text, sentAt: d)
    }

    @Test("Below the sample floor, lean is insufficient")
    func insufficient() {
        let turns = [turn(true, "hey", at(day: 1)), turn(false, "hi", at(day: 2))]
        #expect(EffortBalance.read(turns).lean == .insufficient)
    }

    @Test("A balanced back-and-forth reads as balanced")
    func balanced() {
        var turns: [ThreadTurn] = []
        for i in 0..<8 {
            turns.append(turn(true, "what are you up to today?", at(day: 1 + i, hour: 9)))
            turns.append(turn(false, "just working, you? how was your weekend?", at(day: 1 + i, hour: 11)))
        }
        #expect(EffortBalance.read(turns).lean == .balanced)
    }

    @Test("When THEY go terse and stop asking / initiating, lean is theyUnderInvest")
    func theyUnderInvest() {
        var turns: [ThreadTurn] = []
        // I write long, ask questions, and open every conversation. They reply
        // with one word and never ask anything.
        for i in 0..<8 {
            turns.append(turn(true, "hey! how are you doing, what's new with the job hunt?", at(day: 1 + i, hour: 9)))
            turns.append(turn(false, "fine", at(day: 1 + i, hour: 15)))
        }
        #expect(EffortBalance.read(turns).lean == .theyUnderInvest)
    }

    @Test("When I go terse and they carry it, lean is iUnderInvest (NOT a reach-out trigger)")
    func iUnderInvest() {
        var turns: [ThreadTurn] = []
        for i in 0..<8 {
            turns.append(turn(false, "hey! how are you, what's going on this week?", at(day: 1 + i, hour: 9)))
            turns.append(turn(true, "ok", at(day: 1 + i, hour: 15)))
        }
        #expect(EffortBalance.read(turns).lean == .iUnderInvest)
    }
}
