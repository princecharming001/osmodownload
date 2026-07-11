import Testing
import Foundation
@testable import OsmoBrain

@Suite("Decision brain — parse + the structural sensitive-tier safety backstop")
struct DecisionBrainTests {

    func decision(_ action: RelationshipDecision.Action, conf: Double = 0.9,
                  evidence: [String] = ["a", "b"]) -> RelationshipDecision {
        RelationshipDecision(action: action, confidence: conf, evidence: evidence)
    }

    // MARK: parseResult

    @Test("Parses a reach_out with its move")
    func parseReachOut() {
        let d = DecisionBrain.parseResult("ACTION: reach_out\nMOVE: ask about her trip\nCONFIDENCE: 0.8")
        #expect(d?.action == .reachOut(move: "ask about her trip"))
        #expect(d?.confidence == 0.8)
    }

    @Test("Parses hold_back with days + reason")
    func parseHoldBack() {
        let d = DecisionBrain.parseResult("ACTION: hold_back\nUNTIL: 3 days\nWHY: she read it, give her space")
        #expect(d?.action == .holdBack(untilDays: 3, why: "she read it, give her space"))
    }

    @Test("Parses a gesture with kind/occasion/framing/evidence")
    func parseGesture() {
        let raw = "ACTION: gesture\nGESTURE: condolence\nOCCASION: her dad\nFRAMING: Did something happen with your dad?\nCONFIDENCE: 0.85\nEVIDENCE: she said he passed away; she's been quiet since"
        let d = DecisionBrain.parseResult(raw)
        if case let .gesture(kind, occasion, framing) = d?.action {
            #expect(kind == .condolence)
            #expect(occasion == "her dad")
            #expect(framing.hasSuffix("?"))
        } else { Issue.record("expected a gesture") }
        #expect(d?.evidence.count == 2)
    }

    @Test("No ACTION line → nil")
    func parseNoAction() {
        #expect(DecisionBrain.parseResult("MOVE: something\nCONFIDENCE: 0.9") == nil)
    }

    @Test("Unknown action → nothing")
    func parseUnknownAction() {
        #expect(DecisionBrain.parseResult("ACTION: wander\nCONFIDENCE: 0.5")?.action == .nothing)
    }

    // MARK: enforce — the safety backstop

    @Test("A well-supported hedged condolence LICENSED by a corroborated loss SURVIVES")
    func sensitiveSurvivesWhenValid() {
        let d = decision(.gesture(kind: .condolence, occasion: "her dad",
                                  framing: "Did something happen with your dad?"),
                         conf: 0.85, evidence: ["she said he passed away", "quiet for a week"])
        let out = DecisionBrain.enforce(d, allowedSensitiveKinds: [.condolence])
        if case .gesture = out.action {} else { Issue.record("should have survived") }
    }

    @Test("A sensitive gesture whose kind isn't licensed is downgraded to nothing")
    func sensitiveDowngradedWhenKindNotAllowed() {
        let d = decision(.gesture(kind: .condolence, occasion: "x",
                                  framing: "Did something happen?"),
                         conf: 0.9, evidence: ["a", "b"])
        #expect(DecisionBrain.enforce(d, allowedSensitiveKinds: []).action == .nothing)
    }

    @Test("A corroborated LOSS does NOT license a CELEBRATE gesture (wrong register)")
    func lossDoesNotLicenseCelebrate() {
        // allowed = [.condolence] (a loss was corroborated) but the model emitted
        // a celebrate gesture — must be downgraded, not surfaced as a celebration.
        let d = decision(.gesture(kind: .celebrate, occasion: "x", framing: "Did something great happen?"),
                         conf: 0.95, evidence: ["a", "b"])
        #expect(DecisionBrain.enforce(d, allowedSensitiveKinds: [.condolence]).action == .nothing)
    }

    @Test("Low confidence downgrades an inferred sensitive gesture")
    func lowConfidenceDowngrades() {
        let d = decision(.gesture(kind: .condolence, occasion: "x", framing: "Did something happen?"),
                         conf: 0.5, evidence: ["a", "b"])
        #expect(DecisionBrain.enforce(d, allowedSensitiveKinds: [.condolence]).action == .nothing)
    }

    @Test("Too little evidence downgrades an inferred sensitive gesture")
    func thinEvidenceDowngrades() {
        let d = decision(.gesture(kind: .celebrate, occasion: "x", framing: "Did something great happen?"),
                         conf: 0.9, evidence: ["only one"])
        #expect(DecisionBrain.enforce(d, allowedSensitiveKinds: [.celebrate]).action == .nothing)
    }

    @Test("Non-hedged (assertive) framing downgrades an inferred sensitive gesture")
    func assertiveFramingDowngrades() {
        let d = decision(.gesture(kind: .condolence, occasion: "her dad",
                                  framing: "Send condolences about her father."),  // not a question
                         conf: 0.9, evidence: ["a", "b"])
        #expect(DecisionBrain.enforce(d, allowedSensitiveKinds: [.condolence]).action == .nothing)
    }

    @Test("A birthday gesture LICENSED by a stored date survives WITHOUT the hedged bar")
    func birthdayLicensedByDate() {
        // Factual date kinds don't need a hedged question or ≥2 evidence — the
        // stored date is the evidence. Low confidence, plain framing, no evidence.
        let d = decision(.gesture(kind: .birthday, occasion: "her birthday", framing: "wish her happy birthday"),
                         conf: 0.4, evidence: [])
        if case .gesture = DecisionBrain.enforce(d, allowedSensitiveKinds: [.birthday]).action {} else {
            Issue.record("a date-licensed birthday should survive")
        }
    }

    @Test("A birthday gesture with NO date behind it is downgraded")
    func birthdayWithoutDateDowngraded() {
        let d = decision(.gesture(kind: .birthday, occasion: "?", framing: "wish them happy birthday"),
                         conf: 0.9, evidence: [])
        #expect(DecisionBrain.enforce(d, allowedSensitiveKinds: []).action == .nothing)
    }

    @Test("Non-sensitive gestures are NOT subject to the extra bar")
    func nonSensitivePassesThrough() {
        let d = decision(.gesture(kind: .planHangout, occasion: "coffee", framing: "grab coffee soon"),
                         conf: 0.4, evidence: [])
        if case .gesture = DecisionBrain.enforce(d, allowedSensitiveKinds: []).action {} else {
            Issue.record("non-sensitive gesture should pass through untouched")
        }
    }

    @Test("reach_out / hold_back / nothing are never touched by the sensitive gate")
    func nonGestureUntouched() {
        for action: RelationshipDecision.Action in [.reachOut(move: "x"), .holdBack(untilDays: 2, why: "y"), .nothing] {
            let d = decision(action, conf: 0.1, evidence: [])
            #expect(DecisionBrain.enforce(d, allowedSensitiveKinds: []).action == action)
        }
    }
}
