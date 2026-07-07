import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

@Suite("ThreadIntel — the deeper per-conversation LLM pass")
struct ThreadIntelTests {
    @Test("Full strict output parses every field")
    func fullParse() {
        let raw = """
        TOPIC: Rent Split
        BRIEF: They're waiting on your half of July rent.
        URGENCY: today - due tonight
        ACTION: pay
        QUESTION: no
        COMMITMENTS: You said you'd venmo them Friday
        TONE: terse
        TEMP: cool
        EFFORT: quick
        AUTOMATED: no
        """
        let intel = ThreadIntelBrain.parseResult(raw)
        #expect(intel?.topic == "Rent Split")
        #expect(intel?.brief == "They're waiting on your half of July rent.")
        #expect(intel?.urgency == .today)
        #expect(intel?.urgencyReason == "due tonight")
        #expect(intel?.action == .pay)
        #expect(intel?.openQuestion == false)
        #expect(intel?.commitments == ["You said you'd venmo them Friday"])
        #expect(intel?.tone == "terse")
        #expect(intel?.temperature == .cool)
        #expect(intel?.effort == .quick)
        #expect(intel?.automated == false)
    }

    @Test("Legacy TOPIC/BRIEF-only output (old Insight cache format) still parses")
    func legacyFormatParses() {
        let intel = ThreadIntelBrain.parseResult("TOPIC: Catch-up\nBRIEF: Just checking in after a while.")
        #expect(intel?.topic == "Catch-up")
        #expect(intel?.brief == "Just checking in after a while.")
        #expect(intel?.urgency == nil)
        #expect(intel?.action == nil)
        #expect(intel?.automated == nil)
    }

    @Test("A bare unlabeled line is kept as the brief (loose model / old cache)")
    func bareLineIsBrief() {
        let intel = ThreadIntelBrain.parseResult("Just a plain sentence with no labels at all.")
        #expect(intel?.brief == "Just a plain sentence with no labels at all.")
    }

    @Test("Bad enum values drop to nil, never crash or fail the whole parse")
    func badEnumValuesDropToNil() {
        let raw = "TOPIC: Fine\nURGENCY: extremely urgent\nACTION: yell\nTEMP: spicy"
        let intel = ThreadIntelBrain.parseResult(raw)
        #expect(intel != nil)
        #expect(intel?.topic == "Fine")
        #expect(intel?.urgency == nil)
        #expect(intel?.action == nil)
        #expect(intel?.temperature == nil)
    }

    @Test("Commitments clamp to 2 even when the model lists more")
    func commitmentsClampToTwo() {
        let intel = ThreadIntelBrain.parseResult("COMMITMENTS: one thing; another thing; a third thing")
        #expect(intel?.commitments.count == 2)
        #expect(intel?.commitments == ["one thing", "another thing"])
    }

    @Test("Empty input parses to nil")
    func emptyInputIsNil() {
        #expect(ThreadIntelBrain.parseResult("") == nil)
        #expect(ThreadIntelBrain.parseResult("   \n  ") == nil)
    }

    @Test("Compose includes the TODAY line in the volatile turn, not the cached core")
    func composeIncludesTodayLine() {
        let ctx = InsightContext(personName: "Sam", transcript: [ThreadTurn(fromMe: false, text: "hey")])
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let prompt = ThreadIntelBrain.compose(ctx, now: now)
        #expect(prompt.userTurn.contains("TODAY IS:"))
        #expect(!prompt.systemCore.contains("TODAY IS:"))
        // The cacheable core is identical across calls at different `now` —
        // prompt-caching depends on this.
        let laterPrompt = ThreadIntelBrain.compose(ctx, now: now.addingTimeInterval(86_400))
        #expect(prompt.systemCore == laterPrompt.systemCore)
    }
}
