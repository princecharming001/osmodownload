import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

/// The capture SWEEP lives in AppModel (not unit-testable here), but its pure
/// core — turn a thread's messages into a sentiment score, and turn a run of
/// those samples into a trend — is. This pins that the deterministic path a
/// dormant thread would take produces a sane, monotonic trend.
@Suite("Vibe capture pipeline — deterministic sentiment → series trend")
struct VibeCapturePipelineTests {
    let cal = Calendar.current
    func at(day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: 12))! }

    func score(_ text: String, _ day: Int) -> VibeSample {
        // Mirror the AppModel sweep: last-turn keyword sentiment → a sample.
        let read = ThreadRead.read([ThreadTurn(fromMe: false, text: text, sentAt: at(day: day))], now: at(day: day))
        return VibeSample(threadID: UUID(), sampledAt: at(day: day), score: read.sentiment, source: .keywordSentiment)
    }

    @Test("A thread going from warm to cold reads as cooling")
    func warmToCold() {
        let samples = [
            score("this is great, i love it, thanks so much!", 1),
            score("yeah good, happy about that", 4),
            score("sorry, can't. not happy. this is frustrating", 7),
            score("no. upset and annoyed honestly", 9),
        ]
        let series = VibeSeries.read(samples, now: at(day: 10))
        #expect(series.trend == .cooling)
    }

    @Test("Positive messages produce a non-negative latest score")
    func positiveLatest() {
        let samples = [score("neutral message about lunch", 1),
                       score("ok", 3),
                       score("thanks, this is awesome, love it", 6)]
        let series = VibeSeries.read(samples, now: at(day: 7))
        #expect((series.latest ?? -1) >= 0)
    }
}
