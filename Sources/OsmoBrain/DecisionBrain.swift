import Foundation

/// The LLM half of the Decision Engine. Given ONE gate-selected candidate's
/// evidence, it decides: reach out (with an angle), hold back (with a horizon +
/// reassurance), a gesture beyond text, or — the honest default — nothing.
/// Same house pattern as ThreadIntelBrain: a stable cacheable `systemCore`, a
/// per-request `compose`, a tolerant `parseResult`, and a PURE `enforce` that
/// applies the hard safety rules structurally after parsing.
public enum DecisionBrain {
    /// Stable, prompt-cached. Encodes the principles AND the sensitive-tier bar;
    /// `enforce` is the structural backstop so a stray model response can't slip
    /// a grief card through on prose alone.
    public static let systemCore = """
        You are Osmo's relationship judgment. You are given ONE person and the \
        evidence about where things stand. Decide the single best move right now, \
        and return it as labelled lines. Principles, in order:
        1. PREFER NOTHING. If nothing is genuinely called for, choose NOTHING. An \
        unnecessary nudge is worse than silence.
        2. RESPECT SILENCE. If they read it and their own rhythm says give it time, \
        choose HOLD_BACK — waiting is a real, valuable decision.
        3. Only suggest a GESTURE beyond a text when the evidence clearly supports \
        it. For the SENSITIVE kinds — condolence, celebrate, birthday, anniversary \
        — you must be highly confident, cite at least two independent pieces of \
        evidence, name whose event it is (it must be THIS person's, not someone \
        they mentioned), and phrase it as a HEDGED QUESTION ("Did something happen \
        with your dad?"), never as an assertion of fact. If unsure, choose NOTHING.
        Return these lines (ACTION required, the rest as applicable):
        ACTION: one of reach_out, hold_back, gesture, nothing
        MOVE: (reach_out only) the angle in under 12 words — not the message itself
        UNTIL: (hold_back only) a number of days to wait, or blank
        WHY: (hold_back only) one short reassuring line
        GESTURE: (gesture only) one of check_in, celebrate, birthday, anniversary, \
        condolence, offer_meal, offer_call, offer_help, plan_hangout, send_flowers, \
        send_gift, visit, repair
        OCCASION: (gesture only) the anchor in a few words
        FRAMING: (gesture only) how to raise it — a hedged question for sensitive kinds
        CONFIDENCE: 0.0 to 1.0
        EVIDENCE: semicolon-separated, each a short checkable fact
        No preamble, no quotation marks, no emoji. Use exactly these labels.
        """

    public struct Config: Sendable {
        public var sensitiveMinConfidence: Double
        public var sensitiveMinEvidence: Int
        public init(sensitiveMinConfidence: Double = 0.75, sensitiveMinEvidence: Int = 2) {
            self.sensitiveMinConfidence = sensitiveMinConfidence
            self.sensitiveMinEvidence = sensitiveMinEvidence
        }
    }

    public static func compose(_ candidate: DecisionCandidate, now: Date = Date()) -> ComposedPrompt {
        var s: [String] = []
        s.append(candidate.context)
        if !candidate.triggers.isEmpty {
            s.append("Why this surfaced now: " + candidate.triggers.map { "\($0.kind) (\($0.evidence))" }.joined(separator: "; "))
        }
        if candidate.isSensitive {
            s.append("NOTE: a sensitive life event may be involved — hold to the higher bar.")
        }
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d"
        s.append("Today is \(df.string(from: now)).")
        s.append("Decide the single best move.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }

    /// Tolerant labelled-line parse. Returns nil only when there's no usable
    /// ACTION at all.
    public static func parseResult(_ raw: String) -> RelationshipDecision? {
        var action: String?
        var move: String?, until: Int?, why: String?
        var gesture: String?, occasion: String?, framing: String?
        var confidence = 0.5
        var evidence: [String] = []

        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let colon = t.firstIndex(of: ":") else { continue }
            let label = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch label {
            case "action": action = value.lowercased()
            case "move": move = value.isEmpty ? nil : value
            case "until": until = Int(value.filter(\.isNumber))
            case "why": why = value.isEmpty ? nil : value
            case "gesture": gesture = value.lowercased()
            case "occasion": occasion = value.isEmpty ? nil : value
            case "framing": framing = value.isEmpty ? nil : value
            case "confidence": if let c = Double(value) { confidence = c }
            case "evidence":
                evidence = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            default: break
            }
        }

        guard let action else { return nil }
        let built: RelationshipDecision.Action
        switch action {
        case "reach_out", "reachout":
            built = .reachOut(move: move ?? "reach out")
        case "hold_back", "holdback":
            built = .holdBack(untilDays: until, why: why ?? "give it some time")
        case "gesture":
            guard let g = gesture, let kind = parseGesture(g) else { return RelationshipDecision(action: .nothing, confidence: confidence, evidence: evidence) }
            built = .gesture(kind: kind, occasion: occasion, framing: framing ?? "check in")
        default:
            built = .nothing
        }
        return RelationshipDecision(action: built, confidence: confidence, evidence: evidence)
    }

    /// The STRUCTURAL safety backstop, pure and unit-tested. A sensitive gesture
    /// survives ONLY if:
    ///   • the gate flagged this candidate sensitive (a corroborated occasion),
    ///   • confidence clears the higher bar,
    ///   • there are at least N independent evidence lines,
    ///   • the framing is a hedged QUESTION (ends with "?"), not an assertion.
    /// Otherwise it is downgraded to `nothing` — the model's prose can never
    /// alone push a grief/birthday card to the user.
    public static func enforce(_ decision: RelationshipDecision,
                               candidateIsSensitive: Bool,
                               config: Config = .init()) -> RelationshipDecision {
        guard case let .gesture(kind, _, framing) = decision.action, kind.isSensitive else {
            return decision
        }
        let hedged = framing.trimmingCharacters(in: .whitespaces).hasSuffix("?")
        let ok = candidateIsSensitive
            && decision.confidence >= config.sensitiveMinConfidence
            && decision.evidence.count >= config.sensitiveMinEvidence
            && hedged
        return ok ? decision : RelationshipDecision(action: .nothing,
                                                    confidence: decision.confidence,
                                                    evidence: decision.evidence)
    }

    static let proxyPurpose = "decision"

    private static func parseGesture(_ s: String) -> RelationshipDecision.GestureKind? {
        switch s.replacingOccurrences(of: " ", with: "_") {
        case "check_in", "checkin": return .checkIn
        case "celebrate": return .celebrate
        case "birthday": return .birthday
        case "anniversary": return .anniversary
        case "condolence", "condolences": return .condolence
        case "offer_meal", "meal", "dinner": return .offerMeal
        case "offer_call", "call": return .offerCall
        case "offer_help", "help": return .offerHelp
        case "plan_hangout", "hangout": return .planHangout
        case "send_flowers", "flowers": return .sendFlowers
        case "send_gift", "gift": return .sendGift
        case "visit": return .visit
        case "repair", "repair_rift": return .repairRift
        default: return nil
        }
    }
}

extension SuggestionService {
    /// Decide the single best move for one gate-selected candidate: compose →
    /// generate (on the non-draft `decision` quota lane) → parse → enforce the
    /// sensitive-tier safety bar. Returns `.nothing` rather than throwing when the
    /// model gives nothing usable — a decision engine that goes silent on a bad
    /// response is correct, not broken.
    public func decide(_ candidate: DecisionCandidate, now: Date = Date(),
                       config: DecisionBrain.Config = .init()) async throws -> RelationshipDecision {
        let prompt = DecisionBrain.compose(candidate, now: now)
        let raw = try await generator.generate(
            systemCore: prompt.systemCore, userTurn: prompt.userTurn, count: 1,
            purpose: DecisionBrain.proxyPurpose)
        let parsed = DecisionBrain.parseResult(raw)
            ?? RelationshipDecision(action: .nothing, confidence: 0, evidence: [])
        return DecisionBrain.enforce(parsed, candidateIsSensitive: candidate.isSensitive, config: config)
    }
}
