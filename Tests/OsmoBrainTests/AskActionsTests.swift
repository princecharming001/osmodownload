import Testing
import Foundation
@testable import OsmoBrain

// The Ask actions contract: the model may append ONE trailing ACTIONS line;
// the app parses it tolerantly and NEVER lets a broken block eat the answer.
@Suite("Ask actions — grammar parsing + history composition")
struct AskActionsTests {

    @Test("A well-formed trailing ACTIONS line parses and is stripped from prose")
    func wellFormed() {
        let raw = """
        Madi asked about sending details — you left it at "shoot me a mail."
        ACTIONS: [{"kind":"draft","person":"Madi Thompson"},{"kind":"remind","person":"Madi Thompson","days":3}]
        """
        let (prose, actions) = Ask.split(answer: raw)
        #expect(!prose.contains("ACTIONS:"))
        #expect(prose.hasSuffix("\"shoot me a mail.\""))
        #expect(actions.count == 2)
        #expect(actions[0] == AskAction(kind: .draft, person: "Madi Thompson"))
        #expect(actions[1].days == 3)
    }

    @Test("No ACTIONS line → full prose, zero actions")
    func absent() {
        let (prose, actions) = Ask.split(answer: "Nothing urgent — you're clear.")
        #expect(prose == "Nothing urgent — you're clear.")
        #expect(actions.isEmpty)
    }

    @Test("Malformed JSON degrades to plain prose — the marker text is kept")
    func malformed() {
        let raw = "Here's the read.\nACTIONS: [{\"kind\": \"draft\", busted"
        let (prose, actions) = Ask.split(answer: raw)
        #expect(actions.isEmpty)
        #expect(prose.contains("Here's the read."))
    }

    @Test("Unknown kinds and blank people are dropped; dupes collapse; capped at 3")
    func hardened() {
        let raw = """
        Plenty to do.
        ACTIONS: [{"kind":"teleport","person":"Sam"},{"kind":"draft","person":""},\
        {"kind":"draft","person":"Sam"},{"kind":"draft","person":"Sam"},\
        {"kind":"open","person":"Ana"},{"kind":"remind","person":"Ana","days":99},\
        {"kind":"snooze","person":"Lee","days":0}]
        """
        let (_, actions) = Ask.split(answer: raw)
        #expect(actions.count == 3)                       // cap after dedupe/drops
        #expect(actions[0] == AskAction(kind: .draft, person: "Sam"))
        #expect(actions[1].kind == .open)
        #expect(actions[2].days == 30)                    // 99 clamps to 30
    }

    @Test("History rides into the composed prompt for follow-up continuity")
    func historyComposes() {
        let ctx = AskContext(question: "what about her?",
                             history: ["Q: what did Madi want?", "A: She asked to send details."])
        let p = Ask.compose(ctx)
        #expect(p.userTurn.contains("RECENT CONVERSATION"))
        #expect(p.userTurn.contains("Q: what did Madi want?"))
        #expect(p.userTurn.contains("QUESTION: what about her?"))
        // And the grammar is advertised in the stable core.
        #expect(p.systemCore.contains("ACTIONS:"))
    }
}
