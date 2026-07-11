import Foundation

/// What the brain decided to do about one relationship right now. Typed so the
/// UI (and the safety enforcement) reason over it structurally, not by parsing
/// prose. Deliberately includes "nothing" and "hold back" as first-class
/// outcomes — the system prefers silence over invented outreach.
public struct RelationshipDecision: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Reach out now; `move` is the angle (not the drafted message).
        case reachOut(move: String)
        /// Deliberately wait; `untilDays` is a soft horizon, `why` reassures.
        case holdBack(untilDays: Int?, why: String)
        /// Something beyond a text. `framing` is how to raise it (hedged for the
        /// sensitive kinds), `occasion` the anchor.
        case gesture(kind: GestureKind, occasion: String?, framing: String)
        /// Do nothing — the honest default when nothing is really called for.
        case nothing
    }

    public enum GestureKind: String, Sendable, CaseIterable {
        case checkIn, celebrate, birthday, anniversary, condolence
        case offerMeal, offerCall, offerHelp, planHangout
        case sendFlowers, sendGift, visit, repairRift

        /// The high-harm kinds: getting these WRONG is far costlier than a
        /// routine nudge, so they clear a higher bar (see DecisionBrain.enforce).
        public var isSensitive: Bool {
            switch self {
            case .condolence, .celebrate, .birthday, .anniversary: return true
            default: return false
            }
        }
    }

    public var action: Action
    /// The model's own confidence, 0…1.
    public var confidence: Double
    /// Independent evidence lines that justify the decision (named, checkable).
    public var evidence: [String]

    public init(action: Action, confidence: Double, evidence: [String]) {
        self.action = action
        self.confidence = max(0, min(1, confidence))
        self.evidence = evidence
    }

    public var isSensitive: Bool {
        if case let .gesture(kind, _, _) = action { return kind.isSensitive }
        return false
    }
}
