import Testing
import Foundation
@testable import OsmoBrain

/// The "knows WHEN" suite. Conventions: interval-only fixtures use epoch dates;
/// every hour-sensitive date is built via Calendar.current DateComponents pinned
/// to June 2026 (DST-safe in both hemispheres) so the tests pass in any timezone.
@Suite("Prompt timing — WHEN THIS LANDS")
struct PromptTimingTests {
    let cal = Calendar.current

    func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute))!
    }

    func turn(_ fromMe: Bool, _ text: String, _ date: Date?) -> ThreadTurn {
        ThreadTurn(fromMe: fromMe, text: text, sentAt: date)
    }

    /// Exchanges giving them a stable reply tempo of `gapSeconds`, ending with
    /// MY unanswered message `idleSeconds` before `now` (ball == .mine).
    func rhythmTranscript(replyGaps: [TimeInterval], idle: TimeInterval,
                          now: Date) -> [ThreadTurn] {
        var turns: [ThreadTurn] = []
        var t = now.addingTimeInterval(-idle - Double(replyGaps.count) * 4 * 86_400)
        for (i, gap) in replyGaps.enumerated() {
            turns.append(turn(true, "ping \(i) checking in", t))
            turns.append(turn(false, "pong \(i) sounds good to me", t.addingTimeInterval(gap)))
            t = t.addingTimeInterval(gap + 86_400)
        }
        turns.append(turn(true, "one more thing when you get a sec", now.addingTimeInterval(-idle)))
        return turns
    }

    func timingLines(_ turns: [ThreadTurn], now: Date) -> [String] {
        PromptComposer.timing(read: ThreadRead.read(turns, now: now),
                              partner: PartnerProfile.read(turns),
                              transcript: turns, now: now)
    }

    // MARK: Silence vs rhythm

    @Test("Quiet within THEIR normal rhythm suppresses the gap talk entirely")
    func normalQuietOverride() {
        let now = at(day: 20, hour: 14)
        // They typically take ~2 days; it's been 2.5 days → ratio 1.25, normal.
        let turns = rhythmTranscript(replyGaps: [1.5 * 86_400.0, 2 * 86_400.0, 2.5 * 86_400.0],
                                     idle: 2.5 * 86_400, now: now)
        let lines = timingLines(turns, now: now).joined(separator: " | ")
        #expect(lines.contains("within their normal rhythm"))
        #expect(!lines.contains("a couple days"))          // fixed line must NOT also fire
        #expect(!lines.contains("re-open is warranted"))
    }

    @Test("Quiet 3x+ their rhythm (past the 24h floor) warrants a light re-open")
    func notableDrift() {
        let now = at(day: 20, hour: 14)
        // Median ~4h, idle 36h → ratio 9.
        let turns = rhythmTranscript(replyGaps: [3 * 3600.0, 4 * 3600.0, 5 * 3600.0],
                                     idle: 36 * 3600, now: now)
        let lines = timingLines(turns, now: now).joined(separator: " | ")
        #expect(lines.contains("9x longer than their usual reply rhythm"))
        #expect(lines.contains("no-pressure re-open"))
    }

    @Test("Fast replier a few hours quiet = asleep, not distant (absolute floor)")
    func fastReplierFloor() {
        let now = at(day: 20, hour: 14)
        // Median ~5 min, idle 3h → ratio 36, but idle < 24h → say NOTHING.
        let turns = rhythmTranscript(replyGaps: [240.0, 300.0, 360.0], idle: 3 * 3600, now: now)
        let lines = timingLines(turns, now: now).joined(separator: " | ")
        #expect(!lines.contains("rhythm"))
        #expect(!lines.contains("quiet"))
    }

    @Test("Very long silences use days phrasing, never an absurd multiplier")
    func farPastPhrasing() {
        let now = at(day: 20, hour: 14)
        // Median ~1h, idle 10 days → days line, no "x longer".
        let turns = rhythmTranscript(replyGaps: [3000.0, 3600.0, 4200.0], idle: 10 * 86_400, now: now)
        let lines = timingLines(turns, now: now).joined(separator: " | ")
        #expect(lines.contains("~10 days"))
        #expect(!lines.contains("x longer"))
    }

    @Test("When THEY sent last, their rhythm is never used against the user's own quiet")
    func ballTheirsGating() {
        let now = at(day: 20, hour: 14)
        var turns = rhythmTranscript(replyGaps: [3000.0, 3600.0, 4200.0], idle: 3600, now: now)
        // They replied 5 days ago and the user never answered (ball == .theirs).
        turns.append(turn(false, "let me know what you think", now.addingTimeInterval(-5 * 86_400)))
        let lines = timingLines(turns, now: now).joined(separator: " | ")
        #expect(!lines.contains("their usual reply rhythm"))   // no false "they've gone quiet"
        #expect(lines.contains("a couple days"))               // honest sender-agnostic fallback
    }

    @Test("No rhythm data → the old fixed-threshold line, verbatim")
    func noRhythmFallback() {
        let now = at(day: 20, hour: 14)
        let turns = [
            turn(false, "hey hows it going", now.addingTimeInterval(-3.2 * 86_400)),
            turn(true, "all good! you?", now.addingTimeInterval(-3 * 86_400)),
        ]
        let lines = timingLines(turns, now: now).joined(separator: " | ")
        #expect(lines.contains("a couple days"))
    }

    // MARK: Tempo expectation

    @Test("Slow repliers get a tempo expectation; fast repliers stay unremarked")
    func tempoLine() {
        let now = at(day: 20, hour: 14)
        // Median 2h, idle small (no silence line) → tempo line fires.
        let slow = rhythmTranscript(replyGaps: [6600.0, 7200.0, 7800.0], idle: 3600, now: now)
        #expect(timingLines(slow, now: now).joined().contains("typically reply in ~2h"))
        // Median 5 min → too fast to be worth a line.
        let fast = rhythmTranscript(replyGaps: [240.0, 300.0, 360.0], idle: 600, now: now)
        #expect(!timingLines(fast, now: now).joined().contains("typically reply"))
    }

    // MARK: Active window + moment

    @Test("Active-window match and mismatch both speak, differently")
    func activeWindow() {
        // Six evening messages from them → activeBlock "evenings".
        var turns: [ThreadTurn] = (1...6).map {
            turn(false, "evening msg \($0) here", at(day: $0, hour: 20))
        }
        turns.append(turn(true, "sounds good", at(day: 7, hour: 20)))
        let morning = timingLines(turns, now: at(day: 8, hour: 9)).joined(separator: " | ")
        #expect(morning.contains("usually active evenings"))
        #expect(morning.contains("don't expect a fast reply"))
        let evening = timingLines(turns, now: at(day: 8, hour: 20)).joined(separator: " | ")
        #expect(evening.contains("usual active window (evenings)"))
    }

    @Test("Odd-hour cautions: 1am yes, 6am early-flavored, 2pm silent")
    func momentCautions() {
        let turns = [turn(false, "ok cool", at(day: 10, hour: 14)),
                     turn(true, "great", at(day: 10, hour: 15))]
        #expect(timingLines(turns, now: at(day: 11, hour: 1)).joined().contains("middle of the night"))
        #expect(timingLines(turns, now: at(day: 11, hour: 6)).joined().contains("very early"))
        let daytime = timingLines(turns, now: at(day: 11, hour: 14)).joined()
        #expect(!daytime.contains("middle of the night"))
        #expect(!daytime.contains("very early"))
    }

    @Test("A fresh late-night message from them reads as end-of-day energy — stale ones don't")
    func lateNightLastMessage() {
        let sentAt = at(day: 10, hour: 0, minute: 45)
        let turns = [turn(true, "you up?", at(day: 9, hour: 23, minute: 30)),
                     turn(false, "yeah cant sleep", sentAt)]
        // 2h later: fresh → energy line.
        let fresh = timingLines(turns, now: at(day: 10, hour: 2, minute: 45)).joined()
        #expect(fresh.contains("late at night"))
        // 3 days later: stale → no energy line.
        let stale = timingLines(turns, now: at(day: 13, hour: 2, minute: 45)).joined()
        #expect(!stale.contains("late at night"))
    }

    @Test("hourBlock buckets match activeBlock's, midnight wrap included")
    func hourBlockBoundaries() {
        #expect(PartnerProfile.hourBlock(5) == "mornings")
        #expect(PartnerProfile.hourBlock(10) == "mornings")
        #expect(PartnerProfile.hourBlock(11) == "afternoons")
        #expect(PartnerProfile.hourBlock(16) == "afternoons")
        #expect(PartnerProfile.hourBlock(17) == "evenings")
        #expect(PartnerProfile.hourBlock(22) == "evenings")
        #expect(PartnerProfile.hourBlock(23) == "late nights")
        #expect(PartnerProfile.hourBlock(0) == "late nights")
        #expect(PartnerProfile.hourBlock(4) == "late nights")
    }

    // MARK: End-to-end through the engine

    @Test("The section reaches the real prompt, and carrying + drift coexist")
    func endToEnd() {
        let now = at(day: 20, hour: 14)
        var turns = rhythmTranscript(replyGaps: [3 * 3600.0, 4 * 3600.0, 5 * 3600.0],
                                     idle: 36 * 3600, now: now)
        // Double-text so the anti-chase psychology line fires too.
        turns.append(turn(true, "also wanted to mention one thing", now.addingTimeInterval(-35 * 3600)))
        let ctx = SuggestionContext(relationshipLabel: "my friend", platform: .imessage,
                                    transcript: turns, userIntent: "nudge about plans")
        let p = OsmoBrain().plan(ctx, now: now)
        let turnText = p.prompt.userTurn
        #expect(turnText.contains("WHEN THIS LANDS"))
        #expect(turnText.contains("longer than their usual reply rhythm"))
        #expect(turnText.contains("Do NOT double-text harder"))
        // Determinism: same inputs, same now → byte-identical prompt.
        #expect(OsmoBrain().plan(ctx, now: now).prompt == p.prompt)
    }

    @Test("No timestamps + daytime → no WHEN THIS LANDS section at all")
    func sectionAbsent() {
        let ctx = SuggestionContext(relationshipLabel: "my friend", platform: .imessage,
                                    transcript: [ThreadTurn(fromMe: false, text: "hey")],
                                    userIntent: "say hi back")
        let p = OsmoBrain().plan(ctx, now: at(day: 20, hour: 14))
        #expect(!p.prompt.userTurn.contains("WHEN THIS LANDS"))
    }
}
