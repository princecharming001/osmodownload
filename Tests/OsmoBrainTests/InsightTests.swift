import Testing
import Foundation
@testable import OsmoBrain

@Suite("Insight — the one-line conversation brief")
struct InsightTests {

    @Test("Compose grounds the prompt in goal, memory, trend, and the thread")
    func compose() {
        let ctx = InsightContext(
            personName: "Jay Pao", goalText: "land the internship referral",
            memoryNote: "Met at hackathon; obsessed with F1", trajectoryDriver: "they're replying faster than they used to",
            verdictDetail: "well past their usual ~4h",
            transcript: [ThreadTurn(fromMe: false, text: "did you send the resume yet?")])
        let p = Insight.compose(ctx)
        #expect(p.systemCore == Insight.systemCore)          // stable → cacheable
        #expect(p.userTurn.contains("Jay Pao"))
        #expect(p.userTurn.contains("land the internship referral"))
        #expect(p.userTurn.contains("F1"))
        #expect(p.userTurn.contains("Them: did you send the resume yet?"))
    }

    @Test("Parse takes the first real line, strips wrapping, clamps length")
    func parse() {
        #expect(Insight.parse("\n\n- “He's waiting on the resume you promised Tuesday.”\nExtra line")
                == "He's waiting on the resume you promised Tuesday.")
        #expect(Insight.parse("   ") == nil)
        let long = String(repeating: "x", count: 200)
        #expect(Insight.parse(long)!.count <= 141)
    }

    @Test("parseResult splits TOPIC/BRIEF, tolerates bare lines, clamps labels")
    func parseResult() {
        let both = Insight.parseResult("TOPIC: Internship Referral\nBRIEF: He's waiting on the resume you promised Tuesday.")
        #expect(both?.topic == "Internship Referral")
        #expect(both?.brief == "He's waiting on the resume you promised Tuesday.")

        // Bare single line = brief only (older cache / loose model).
        let bare = Insight.parseResult("They still owe you the contract redlines.")
        #expect(bare?.topic == nil)
        #expect(bare?.brief == "They still owe you the contract redlines.")

        // A rambling "label" is dropped, never chip-rendered.
        let longTopic = Insight.parseResult("TOPIC: this is way too long to be a label honestly\nBRIEF: fine")
        #expect(longTopic?.topic == nil)
        #expect(longTopic?.brief == "fine")

        #expect(Insight.parseResult("") == nil)
    }

    @Test("Fallback prefers the open question, then goal, then memory, then trend")
    func fallback() {
        let question = InsightContext(personName: "A",
            transcript: [ThreadTurn(fromMe: false, text: "so are we on for friday?")])
        #expect(Insight.fallback(question)?.contains("asked a question") == true)

        let goal = InsightContext(personName: "A", goalText: "repair the friendship")
        #expect(Insight.fallback(goal)?.contains("repair the friendship") == true)

        let memory = InsightContext(personName: "A", memoryNote: "Sister's wedding is next month")
        #expect(Insight.fallback(memory)?.contains("Sister's wedding") == true)

        let trend = InsightContext(personName: "A", trajectoryDriver: "their messages have dropped off lately")
        #expect(Insight.fallback(trend)?.contains("dropped off") == true)

        #expect(Insight.fallback(InsightContext(personName: "A")) == nil)
    }
}
