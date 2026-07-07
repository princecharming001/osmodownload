import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

@Suite("VoiceStats — how the USER themselves texts")
struct VoiceStatsTests {
    private func turn(_ fromMe: Bool, _ text: String, hour: Int = 12, day: Int = 1) -> ThreadTurn {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = day; comps.hour = hour; comps.minute = 0
        let date = Calendar.current.date(from: comps)
        return ThreadTurn(fromMe: fromMe, text: text, sentAt: date)
    }

    @Test("Basic rates/averages compute from the user's own outbound turns only")
    func basicRates() {
        let turns: [Platform: [ThreadTurn]] = [
            .imessage: [
                turn(false, "hey what's up"),
                turn(true, "not much just chilling 😊"),
                turn(true, "wanna grab food later?"),
                turn(false, "sure!"),
                turn(true, "cool see you at 7"),
            ],
        ]
        let stats = VoiceStats.compute(turns)
        #expect(stats.overall.msgCount == 3)   // only the fromMe:true turns count
        #expect(stats.overall.questionRate > 0)   // "wanna grab food later?" has a "?"
        #expect(stats.overall.emojiRate > 0)       // one message has an emoji
    }

    @Test("isEmpty is true under 20 sent messages")
    func isEmptyThreshold() {
        let few: [Platform: [ThreadTurn]] = [.imessage: Array(repeating: turn(true, "hi there friend"), count: 5)]
        #expect(VoiceStats.compute(few).isEmpty)
        let many: [Platform: [ThreadTurn]] = [.imessage: Array(repeating: turn(true, "hi there friend"), count: 25)]
        #expect(!VoiceStats.compute(many).isEmpty)
    }

    @Test("Per-platform buckets are independent and only present when non-empty")
    func perPlatformBucketing() {
        let turns: [Platform: [ThreadTurn]] = [
            .imessage: [turn(true, "yo"), turn(true, "sup")],
            .linkedin: [turn(true, "Thank you for connecting, I would love to discuss further.")],
            .gmail: [],
        ]
        let stats = VoiceStats.compute(turns)
        #expect(stats.perPlatform[.imessage]?.msgCount == 2)
        #expect(stats.perPlatform[.linkedin]?.msgCount == 1)
        #expect(stats.perPlatform[.gmail] == nil)   // empty bucket is dropped, not zero-filled
        // LinkedIn message is longer than the iMessage ones.
        #expect((stats.perPlatform[.linkedin]?.avgWords ?? 0) > (stats.perPlatform[.imessage]?.avgWords ?? 0))
    }

    @Test("My-reply-speed median honors the same clamps as PartnerProfile (30s–7d)")
    func medianReplySpeedClamped() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 1; comps.hour = 9
        let base = Calendar.current.date(from: comps)!
        // Them at t, me at t+5min, three times → my reply speed ≈ 5 min.
        var turns: [ThreadTurn] = []
        for i in 0..<3 {
            let theirTime = base.addingTimeInterval(Double(i) * 3600)
            turns.append(ThreadTurn(fromMe: false, text: "ping", sentAt: theirTime))
            turns.append(ThreadTurn(fromMe: true, text: "pong back quick", sentAt: theirTime.addingTimeInterval(300)))
        }
        let stats = VoiceStats.compute([.imessage: turns])
        #expect(stats.medianReplySeconds != nil)
        #expect(abs((stats.medianReplySeconds ?? 0) - 300) < 1)
    }

    @Test("Signature phrases: stopword-filtered, counted once per message, need ≥3 messages, deterministic order")
    func topPhrasesExtraction() {
        let texts = [
            "let me know when you land",
            "let me know when you're free",
            "let me know when you get there",
            "just a random one off message here",
        ]
        let phrases = VoiceStats.extractTopPhrases(texts)
        #expect(phrases.contains("let me"))
        #expect(phrases.contains("me know"))
        // A phrase seen in only one message never qualifies (needs ≥3).
        #expect(!phrases.contains("random one"))
        #expect(phrases.count <= 8)
    }

    @Test("A phrase repeated twice WITHIN one message counts once, not twice, for that message")
    func phraseCountsOncePerMessage() {
        let texts = [
            "no worries no worries about it",
            "no worries at all",
            "no worries seriously",
        ]
        // "no worries" appears twice in message 1 but must still only count
        // message 1 as ONE occurrence — 3 total messages, exactly at threshold.
        let phrases = VoiceStats.extractTopPhrases(texts)
        #expect(phrases.contains("no worries"))
    }
}

@Suite("VoicePersona — the AI-written texting narrative")
struct VoicePersonaTests {
    private func sampleStats() -> VoiceStats {
        VoiceStats(overall: .init(msgCount: 100, avgWords: 8, lowercaseShare: 0.8, emojiRate: 0.2,
                                  endPunctRate: 0.3, exclamRate: 0.1, questionRate: 0.2),
                   medianReplySeconds: 400, activeBlock: "evenings",
                   topPhrases: ["sounds good", "let me know"],
                   perPlatform: [:])
    }

    @Test("Parses three paragraphs from a blank-line-separated response")
    func parsesBlankLineSeparated() {
        let raw = "You write short, casual messages.\n\nYou stay consistent across platforms.\n\nYou often say \"sounds good.\""
        let result = VoicePersona.parseResult(raw)
        #expect(result?.paragraphs.count == 3)
    }

    @Test("Tolerates numbered headers (1. 2. 3.)")
    func tolerateNumberedHeaders() {
        let raw = "1. Short and casual.\n2. Consistent everywhere.\n3. Says \"let me know\" a lot."
        let result = VoicePersona.parseResult(raw)
        #expect(result?.paragraphs.count == 3)
        #expect(result?.paragraphs[0] == "Short and casual.")
    }

    @Test("Clamps to 3 paragraphs even if the model rambles on")
    func clampsToThree() {
        let raw = "One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive."
        #expect(VoicePersona.parseResult(raw)?.paragraphs.count == 3)
    }

    @Test("Fallback is never blank and reflects the actual stats")
    func fallbackIsGrounded() {
        let result = VoicePersona.fallback(sampleStats())
        #expect(!result.paragraphs.isEmpty)
        #expect(result.paragraphs.joined().contains("8"))
    }

    @Test("Empty stats produce an honest not-enough-data fallback")
    func emptyStatsFallback() {
        let empty = VoiceStats(overall: .empty, medianReplySeconds: nil, activeBlock: nil,
                               topPhrases: [], perPlatform: [:])
        let result = VoicePersona.fallback(empty)
        #expect(result.paragraphs.count == 1)
        #expect(result.paragraphs[0].lowercased().contains("not enough"))
    }
}
