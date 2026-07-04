import Foundation

/// The selected plan for one message: which techniques apply, in priority order.
public struct StrategyPlan: Equatable, Sendable {
    public var move: Move
    public var goalKind: GoalKind
    public var register: RelationshipRegister
    public var techniques: [Technique]
}

/// Selects the applicable psychology techniques for a message from
/// (move × goal × register × thread state). This is the engine's judgment layer —
/// pure and unit-tested (assert an apology-to-partner picks the clean-apology +
/// repair techniques; a negotiate-with-client picks labeling + calibrated
/// questions; a their-open-question always gets answered first).
public enum Strategy {
    /// How many techniques to inject — enough to shape the message, few enough to
    /// keep the model focused and the "why" legible.
    public static let cap = 4

    public static func plan(move: Move, goalKind: GoalKind,
                            register: RelationshipRegister, read: ThreadRead) -> StrategyPlan {
        var ids: [String] = []

        // Highest priority: if they asked something, answer it first.
        if read.hasOpenQuestion { ids.append("answer-first") }

        // Move-driven core.
        switch move {
        case .apologize:
            ids += ["own-it-apology"]
            if register.isClose { ids += ["repair-attempt", "turn-toward-bid"] }
        case .decline:
            ids += ["face-saving-no"]
        case .comfort:
            ids += ["validate-first", "specific-presence"]
        case .deliverHardNews:
            ids += ["news-first"]
            if register.isClose { ids += ["repair-attempt"] }
        case .nudge:
            ids += ["one-clear-ask", "easy-yes"]
        case .ask:
            ids += ["one-clear-ask", "easy-yes"]
        case .negotiate:
            ids += ["labeling", "calibrated-question", "accusation-audit"]
        case .deescalate:
            ids += ["labeling", "repair-attempt", "soft-startup"]
        case .persuade:
            ids += ["reciprocity", "commitment", "anchor-future"]
        case .flirt:
            ids += ["easy-yes"]
        case .checkIn:
            ids += ["turn-toward-bid", "specific-presence"]
        case .celebrate:
            ids += ["turn-toward-bid"]
        case .thank:
            break   // clarity of specific gratitude handled in prompt; no heavy technique
        case .scheduleTime:
            ids += ["easy-yes", "one-clear-ask"]
        case .answer, .smallTalk, .plain:
            break
        }

        // Goal-driven overlay (advance the relationship, not just this message).
        switch goalKind {
        case .closeDeal:        ids += ["calibrated-question", "anchor-future", "commitment"]
        case .getMeeting:       ids += ["easy-yes", "one-clear-ask"]
        case .negotiate:        ids += ["labeling", "calibrated-question"]
        case .professionalAsk:  ids += ["reciprocity", "one-clear-ask", "easy-yes"]
        case .askFavor:         ids += ["easy-yes"]
        case .rebuildTrust:     ids += ["own-it-apology", "turn-toward-bid", "specific-presence"]
        case .deescalate:       ids += ["labeling", "repair-attempt"]
        case .deepenBond:       ids += ["turn-toward-bid", "specific-presence"]
        case .reconnect:        ids += ["turn-toward-bid", "easy-yes"]
        case .getDate:          ids += ["easy-yes"]
        case .maintainCadence:  ids += ["turn-toward-bid"]
        case .freeform:         break
        }

        // Style matching whenever we can see their message.
        if read.theirLastText != nil { ids.append("lsm-match") }

        // Register filter: for high-formality registers, drop the warm-relationship
        // family unless the move is explicitly a repair/comfort.
        let allowWarm = register.isClose || [.apologize, .comfort, .deescalate].contains(move)
        var resolved: [Technique] = []
        var seen = Set<String>()
        for id in ids where !seen.contains(id) {
            let tech = TechniqueCatalog.by(id)
            if !allowWarm && tech.family == .relationship { continue }
            seen.insert(id)
            resolved.append(tech)
        }

        // Ensure LSM survives the cap (it's cheap and always helps) by keeping it
        // if present even when we trim.
        let capped = Array(resolved.prefix(cap))
        var final = capped
        if let lsm = resolved.first(where: { $0.id == "lsm-match" }), !final.contains(lsm) {
            final[final.count - 1] = lsm
        }

        return StrategyPlan(move: move, goalKind: goalKind, register: register, techniques: final)
    }
}

extension RelationshipRegister {
    /// Close relationships where warm relationship-repair techniques fit.
    public var isClose: Bool {
        switch self {
        case .partner, .crush, .situationship, .bestFriend, .friend,
             .parent, .sibling, .family, .ex: return true
        default: return false
        }
    }
}
