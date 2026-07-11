import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

@Suite("Vibe series — warming/steady/cooling slope over recent samples")
struct VibeSeriesTests {
    let cal = Calendar.current
    func at(day: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: 12))!
    }
    func sample(_ day: Int, _ score: Double) -> VibeSample {
        VibeSample(threadID: UUID(), sampledAt: at(day: day), score: score, source: .keywordSentiment)
    }

    @Test("Below the sample floor, trend is insufficient")
    func insufficient() {
        let s = VibeSeries.read([sample(1, 0.5), sample(2, 0.4)], now: at(day: 3))
        #expect(s.isEmpty)
        #expect(s.trend == .insufficient)
    }

    @Test("A steadily rising score reads as warming")
    func warming() {
        let samples = [sample(1, -0.5), sample(3, -0.2), sample(5, 0.1), sample(7, 0.5)]
        let s = VibeSeries.read(samples, now: at(day: 8))
        #expect(s.trend == .warming)
        #expect((s.slopePerDay ?? 0) > 0)
    }

    @Test("A steadily falling score reads as cooling")
    func cooling() {
        let samples = [sample(1, 0.6), sample(3, 0.2), sample(5, -0.1), sample(7, -0.5)]
        let s = VibeSeries.read(samples, now: at(day: 8))
        #expect(s.trend == .cooling)
    }

    @Test("Flat scores read as steady")
    func steady() {
        let samples = [sample(1, 0.2), sample(3, 0.2), sample(5, 0.2), sample(7, 0.2)]
        let s = VibeSeries.read(samples, now: at(day: 8))
        #expect(s.trend == .steady)
    }

    @Test("Samples older than the 14d window are excluded")
    func windowExcludesOld() {
        // Two ancient samples + three recent flat ones.
        let samples = [sample(1, -1.0), sample(2, -1.0), sample(20, 0.3), sample(21, 0.3), sample(22, 0.3)]
        let s = VibeSeries.read(samples, now: at(day: 23))
        #expect(s.sampleCount == 3)          // ancient two dropped
        #expect(s.latest == 0.3)
    }
}
