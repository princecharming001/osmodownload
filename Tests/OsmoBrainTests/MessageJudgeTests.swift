import Testing
import Foundation
@testable import OsmoBrain
import OsmoCore

@Suite("MessageJudge — score/why/risks/alternatives parsing")
struct MessageJudgeTests {
    @Test("Full well-formed output parses completely")
    func fullParse() {
        let raw = """
        SCORE: 8/10
        WORKS:
        - Direct and warm
        - Answers their question first
        RISKS:
        - A little long for how you two usually text
        ALT1: Shorter — Sounds good, see you at 7.
        ALT2: Warmer — Can't wait, see you at 7! 😊
        """
        let result = MessageJudge.parseResult(raw)
        #expect(result?.score == 8)
        #expect(result?.works == ["Direct and warm", "Answers their question first"])
        #expect(result?.risks == ["A little long for how you two usually text"])
        #expect(result?.alternatives.count == 2)
        #expect(result?.alternatives[0].label == "Shorter")
        #expect(result?.alternatives[0].text == "Sounds good, see you at 7.")
        #expect(result?.alternatives[1].label == "Warmer")
    }

    @Test("Score variants all parse: bare number, fraction, dashed phrasing")
    func scoreVariants() {
        #expect(MessageJudge.parseResult("SCORE: 7")?.score == 7)
        #expect(MessageJudge.parseResult("SCORE: 7/10")?.score == 7)
        #expect(MessageJudge.parseResult("Score - 9")?.score == 9)
        #expect(MessageJudge.parseResult("SCORE: 10/10")?.score == 10)
    }

    @Test("Missing sections are tolerated — partial output still parses")
    func missingSectionsTolerated() {
        let result = MessageJudge.parseResult("SCORE: 6\nRISKS:\n- Might read as curt")
        #expect(result?.score == 6)
        #expect(result?.works == [])
        #expect(result?.risks == ["Might read as curt"])
    }

    @Test("Alternative labels split on em-dash, hyphen, or colon")
    func altSplitVariants() {
        #expect(MessageJudge.parseAlt("ALT1: Direct — just say no.")?.label == "Direct")
        #expect(MessageJudge.parseAlt("ALT1: Direct - just say no.")?.label == "Direct")
        #expect(MessageJudge.parseAlt("ALT1: Direct: just say no.")?.label == "Direct")
    }

    @Test("Completely empty/unrecognized input parses to nil")
    func emptyInputIsNil() {
        #expect(MessageJudge.parseResult("") == nil)
        #expect(MessageJudge.parseResult("blah blah nothing structured") == nil)
    }

    @Test("merge folds ToneCheck flags into risks, deduping by title, clamped to 4")
    func mergeFoldsToneCheckFlags() {
        var result = MessageJudge.Result(score: 7, risks: ["Reads like chasing — you already sent last"])
        let toneCheck = ToneCheck(
            flags: [
                ToneCheck.Flag(title: "Reads like chasing", detail: "already covered by the model"),
                ToneCheck.Flag(title: "3 exclamation points", detail: "dial it back"),
                ToneCheck.Flag(title: "2 sorries", detail: "one clean sorry lands stronger"),
                ToneCheck.Flag(title: "Hedging stacks up", detail: "say it straight"),
            ],
            verdict: "Worth a quick second pass.", sendable: false)
        let merged = MessageJudge.merge(result, toneCheck: toneCheck)
        // The already-covered flag (matched by title substring) is NOT duplicated.
        #expect(merged.risks.filter { $0.contains("Reads like chasing") }.count == 1)
        // Clamped to 4 total.
        #expect(merged.risks.count <= 4)
        result = merged
        #expect(result.score == 7)
    }
}
