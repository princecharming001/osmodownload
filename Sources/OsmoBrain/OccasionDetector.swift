import Foundation
import OsmoCore

/// Scans inbound text for occasions worth remembering or acting on: concrete
/// dates (birthdays, anniversaries, deadlines) and — held to a far higher bar —
/// sensitive life events (a loss, a big celebration). This is DETECTION ONLY,
/// and for the sensitive kinds it produces a *candidate flagged for LLM
/// confirmation*, never a decision: a regex hit alone must never be enough to
/// surface "sorry for your loss" to a user, because the cost of being wrong is
/// enormous.
///
/// Collision safety (the load-bearing design choice): the codebase already
/// shipped a "passed" vs "passed away" collision in Moves.swift where a short
/// generic keyword could hijack a longer opposite-meaning phrase, saved only by
/// fragile table ordering. This detector never keys a sensitive reading on an
/// ambiguous bare stem ("passed", "lost", "dead", "gone"). Loss is matched ONLY
/// on unambiguous multi-word phrases ("passed away", "lost her mom", "rest in
/// peace"), so "passed the exam", "dead to me", "killed it", and "lost my keys"
/// can never read as loss. A NEGATIVE test suite pins exactly these.
public struct OccasionCandidate: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case birthday, anniversary, deadline          // factual, low-risk
        case possibleLoss, possibleCelebration        // sensitive — need confirmation
    }
    public var kind: Kind
    /// The phrase that matched — evidence for the confirmation step, never shown raw.
    public var evidence: String
    /// Sensitive kinds are ALWAYS true: a keyword hit is a candidate, not a fact.
    /// The DecisionBrain must confirm the full turn before anything surfaces.
    public var needsLLMConfirmation: Bool

    public var isSensitive: Bool {
        kind == .possibleLoss || kind == .possibleCelebration
    }

    public init(kind: Kind, evidence: String, needsLLMConfirmation: Bool) {
        self.kind = kind
        self.evidence = evidence
        self.needsLLMConfirmation = needsLLMConfirmation
    }
}

/// A sensitive life event (loss/celebration) that has been CORROBORATED beyond a
/// single keyword hit — the only thing allowed to justify a sensitive-tier
/// decision. Produced by the LLM-confirmation pass (a later phase); the gate
/// only ever reads it, and enforces that heuristics can never fabricate one.
public struct SensitiveOccasion: Equatable, Sendable {
    public var kind: OccasionCandidate.Kind   // .possibleLoss or .possibleCelebration
    /// How many independent inbound messages support this reading (≥2 to fire).
    public var corroborationCount: Int
    /// The event is about the THREAD PARTICIPANT, not a third party they mentioned.
    public var subjectIsParticipant: Bool
    public var evidence: [String]

    public init(kind: OccasionCandidate.Kind, corroborationCount: Int,
                subjectIsParticipant: Bool, evidence: [String]) {
        self.kind = kind
        self.corroborationCount = corroborationCount
        self.subjectIsParticipant = subjectIsParticipant
        self.evidence = evidence
    }
}

public enum OccasionDetector {
    // Unambiguous LOSS phrases only — every one is multi-word or a fixed idiom
    // that cannot appear in an achievement/mundane sentence. NEVER bare "passed",
    // "lost", "dead", "gone".
    private static let lossPhrases = [
        "passed away", "passed on", "rest in peace", "condolence", "condolences",
        "funeral", "memorial service", "lost her mom", "lost his mom", "lost her dad",
        "lost his dad", "lost their mom", "lost their dad", "lost my mom", "lost my dad",
        "lost her mother", "lost his mother", "lost her father", "lost his father",
        "in a better place", "no longer with us",
    ]

    // Positive life events. "engaged"/"promotion" are specific enough; bare
    // "passed" is deliberately EXCLUDED here (that was the collision).
    private static let celebrationPhrases = [
        "got engaged", "we're engaged", "got married", "got the job", "got promoted",
        "new job", "landed the job", "we're expecting", "having a baby",
        "passed the bar", "passed my exam", "passed the exam", "graduated",
    ]

    private static let birthdayPhrases = [
        "my birthday", "your birthday", "her birthday", "his birthday",
        "their birthday", "turning", "b-day", "bday",
    ]

    private static let anniversaryPhrases = ["anniversary", "our anniversary"]

    private static let deadlinePhrases = [
        "deadline", "due date", "due by", "due on", "submit by", "by end of",
    ]

    /// Words that, if present, VETO a loss reading — "dead to me", "killed it",
    /// "dying to", "dead tired" etc. carry death-adjacent stems in non-death
    /// idioms. Kept alongside the phrase-only matching as belt-and-suspenders.
    private static let lossVetoIdioms = [
        "dead to me", "killed it", "dying to", "dead tired", "dead serious",
        "drop dead", "over my dead body",
    ]

    public static func scan(_ text: String?) -> [OccasionCandidate] {
        guard let raw = text?.lowercased(), !raw.isEmpty else { return [] }
        var out: [OccasionCandidate] = []

        // Factual kinds first (order doesn't affect correctness — no shared stems).
        if let hit = firstMatch(raw, birthdayPhrases) {
            out.append(.init(kind: .birthday, evidence: hit, needsLLMConfirmation: false))
        }
        if let hit = firstMatch(raw, anniversaryPhrases) {
            out.append(.init(kind: .anniversary, evidence: hit, needsLLMConfirmation: false))
        }
        if let hit = firstMatch(raw, deadlinePhrases) {
            out.append(.init(kind: .deadline, evidence: hit, needsLLMConfirmation: false))
        }

        // Sensitive kinds — always flagged for confirmation, never surfaced on
        // the keyword hit alone. Loss is suppressed entirely if a veto idiom is
        // present.
        let vetoed = lossVetoIdioms.contains { TextMatch.word(raw, $0) }
        if !vetoed, let hit = firstMatch(raw, lossPhrases) {
            out.append(.init(kind: .possibleLoss, evidence: hit, needsLLMConfirmation: true))
        }
        if let hit = firstMatch(raw, celebrationPhrases) {
            out.append(.init(kind: .possibleCelebration, evidence: hit, needsLLMConfirmation: true))
        }
        return out
    }

    private static func firstMatch(_ haystack: String, _ needles: [String]) -> String? {
        needles.first { TextMatch.word(haystack, $0) }
    }
}
