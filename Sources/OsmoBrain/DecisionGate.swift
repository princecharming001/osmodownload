import Foundation
import OsmoCore

/// The deterministic front half of the Decision Engine: given the composed
/// relationship models, decide WHICH people are worth the LLM's attention right
/// now, score them, and hand a bounded, deduped, ranked shortlist to the
/// DecisionBrain. Pure and fully unit-tested — no LLM, no store, no clock but
/// the one passed in.
///
/// Scoring is CLUSTER-AWARE, not additive (the #1 correctness fix from the
/// design critique): two triggers that measure the same underlying fact — e.g.
/// "unusual silence" and "left on read past their p75", or "trajectory cooling"
/// and "vibe cooling" — must NOT stack, or a merely-busy week outscores a real
/// birthday. Within a cluster we take the MAX; independent clusters (date,
/// promise, effort) stack.
///
/// The sensitive tier (loss/celebration) is held far higher: it can ONLY fire
/// from a corroborated `sensitiveOccasion` (≥2 independent messages, about the
/// actual participant), never from a noisy heuristic, and a candidate that has
/// only heuristic triggers can never be marked sensitive.
public enum DecisionCluster: String, Sendable, CaseIterable {
    case date, promise, silence, cooling, effort, bid, sensitive
}

public struct DecisionTrigger: Equatable, Sendable {
    public var cluster: DecisionCluster
    public var kind: String
    public var score: Int
    public var evidence: String
}

public struct DecisionCandidate: Equatable, Sendable {
    public var threadID: UUID
    public var personID: UUID?
    public var displayName: String
    public var isGroup: Bool
    public var triggers: [DecisionTrigger]
    public var score: Int
    public var inputHash: String
    public var isSensitive: Bool
    /// Which sensitive gesture kinds the real evidence LICENSES — a corroborated
    /// loss licenses `.condolence`, a corroborated celebration `.celebrate`, an
    /// upcoming stored birthday `.birthday`, etc. The brain's output is held to
    /// this: it can't answer a loss with a "celebrate", and can't invent a
    /// birthday gesture with no date behind it.
    public var allowedSensitiveKinds: Set<RelationshipDecision.GestureKind>
    public var context: String
}

public enum DecisionGate {
    public struct Config: Sendable {
        /// Max candidates returned per `evaluate()` call. NOTE: this bounds ONE
        /// run, not a true rolling day — successive runs drain different threads
        /// (dedup keeps a decided state from re-billing for its TTL). A real
        /// per-day spend ceiling is P6's DecisionBudget; until then the shadow
        /// runner's 30-min throttle + 24h dedup bound first-day spend to roughly
        /// the eligible-thread count, not this number.
        public var dailyBudget: Int
        public var hardCap: Int
        public var dateHorizon: TimeInterval
        public var minSensitiveCorroboration: Int
        public init(dailyBudget: Int = 10, hardCap: Int = 20,
                    dateHorizon: TimeInterval = 14 * 86_400,
                    minSensitiveCorroboration: Int = 2) {
            self.dailyBudget = dailyBudget
            self.hardCap = hardCap
            self.dateHorizon = dateHorizon
            self.minSensitiveCorroboration = minSensitiveCorroboration
        }
    }

    /// Runtime suppression state, injected so the gate stays pure. Populated by
    /// the feedback loop (a later phase); empty here = nothing suppressed.
    public struct Suppressors: Sendable {
        /// Per-thread "don't nudge until" — a hard silence window.
        public var quietUntil: [UUID: Date]
        /// inputHashes of decisions still alive (already surfaced this exact
        /// state) — never re-bill the LLM for a state that hasn't changed.
        public var activeInputHashes: Set<String>
        public init(quietUntil: [UUID: Date] = [:], activeInputHashes: Set<String> = []) {
            self.quietUntil = quietUntil
            self.activeInputHashes = activeInputHashes
        }
    }

    // Trigger scores.
    static let scoreUpcomingDate = 50
    static let scoreUnresolvedPromise = 35
    static let scoreGoodTimeSilence = 30
    static let scoreLeftOnRead = 30
    static let scoreTrajectoryCooling = 25
    static let scoreVibeCooling = 25
    static let scoreEffortImbalance = 15
    static let scoreBidNeglect = 28   // a psychologically-weighted connection signal
    static let scoreSensitive = 60   // highest, but gated hardest

    public static func evaluate(_ models: [RelationshipModel], now: Date,
                                config: Config = .init(),
                                suppressors: Suppressors = .init(),
                                priors: [UUID: PersonPrior] = [:]) -> [DecisionCandidate] {
        var candidates: [DecisionCandidate] = []

        for m in models {
            // Hard suppressors that drop the whole candidate.
            if m.isGroup { continue }                              // groups aren't relationships
            if m.intel?.automated == true { continue }             // newsletters/bots
            if let until = suppressors.quietUntil[m.threadID], until > now { continue }

            let triggers = buildTriggers(m, now: now, config: config)
            guard !triggers.isEmpty else { continue }

            let prior = m.personID.flatMap { priors[$0] }
            let dominant = triggers.max(by: { $0.score < $1.score })?.cluster ?? .silence
            // Date/promise/sensitive are concrete/important — exempt from the
            // learned quiet windows (a real birthday still surfaces even if the
            // user's been dismissing this person's cooling nudges).
            let hasHardTrigger = triggers.contains {
                $0.cluster == .date || $0.cluster == .promise || $0.cluster == .sensitive
            }
            if !hasHardTrigger, let prior, prior.isQuiet(family: dominant.rawValue, now: now) { continue }

            // Weight the score by what we've learned about nudging this person on
            // this family — but ONLY for heuristic candidates. A hard trigger
            // (real date / promise / sensitive) keeps its full score so learned
            // dislike of this person's cooling nudges can never push their actual
            // birthday below other people's routine nudges and off the budget cut.
            let weight = hasHardTrigger ? 1.0 : (prior?.nudgeWeight(family: dominant.rawValue) ?? 1.0)
            let score = Int((Double(clusterScore(triggers)) * weight).rounded())
            let isSensitive = triggers.contains { $0.cluster == .sensitive }
            let hash = inputHash(m, triggers: triggers)

            // Already have a live decision for this exact state — don't re-bill.
            if suppressors.activeInputHashes.contains(hash) { continue }

            // Drop gesture kinds the user has repeatedly dismissed (life-event
            // kinds are never category-suppressed — see PersonPrior).
            var allowed = allowedSensitiveKinds(m, now: now, config: config)
            if let prior {
                for raw in prior.suppressedGestureKinds {
                    if let g = RelationshipDecision.GestureKind(rawValue: raw) { allowed.remove(g) }
                }
            }

            candidates.append(DecisionCandidate(
                threadID: m.threadID, personID: m.personID, displayName: m.displayName,
                isGroup: m.isGroup, triggers: triggers, score: score, inputHash: hash,
                isSensitive: isSensitive, allowedSensitiveKinds: allowed,
                context: m.decisionContext(now: now)))
        }

        // Deterministic order: score desc, then threadID string asc (stable —
        // no flapping which candidates make the budget cut across reloads).
        candidates.sort {
            $0.score != $1.score ? $0.score > $1.score
                : $0.threadID.uuidString < $1.threadID.uuidString
        }
        return Array(candidates.prefix(min(config.dailyBudget, config.hardCap)))
    }

    // MARK: Trigger construction

    private static func buildTriggers(_ m: RelationshipModel, now: Date,
                                      config: Config) -> [DecisionTrigger] {
        var out: [DecisionTrigger] = []

        // — date cluster (independent; the soonest within horizon) —
        let upcoming = m.importantDates
            .compactMap { d -> (ImportantDate, Date)? in d.nextOccurrence(after: now).map { (d, $0) } }
            .filter { $0.1.timeIntervalSince(now) <= config.dateHorizon && $0.1 >= now }
            .min { $0.1 < $1.1 }
        if let (d, when) = upcoming {
            let days = max(0, Int(when.timeIntervalSince(now) / 86_400))
            out.append(.init(cluster: .date, kind: "upcomingDate",
                             score: scoreUpcomingDate, evidence: "\(d.label) in ~\(days)d"))
        }

        // — promise cluster (independent) —
        if let commits = m.intel?.commitments, !commits.isEmpty {
            out.append(.init(cluster: .promise, kind: "unresolvedPromise",
                             score: scoreUnresolvedPromise,
                             evidence: "you promised: \(commits.joined(separator: "; "))"))
        }

        // — silence cluster (MAX within) —
        var silence: [DecisionTrigger] = []
        let silenceState = m.rhythm.silence(sinceLastMessageAt: m.lastMessageAt, now: now)
        if m.verdict.kind == .goodTime, silenceState == .unusual {
            silence.append(.init(cluster: .silence, kind: "goodTimeSilence",
                                 score: scoreGoodTimeSilence,
                                 evidence: "well past their rhythm — a nudge lands as thoughtful"))
        }
        // Left on read: I sent last, they actually READ it (real receipt), and
        // it's past 2× their p75. Without the read receipt this is just a normal
        // conversation lull, not a snub — requiring it stops the trigger from
        // over-firing on every thread that happens to have paused.
        if m.read.ball == .mine, m.lastOutboundReadAt != nil, silenceState == .unusual {
            silence.append(.init(cluster: .silence, kind: "leftOnRead", score: scoreLeftOnRead,
                                 evidence: "read but unanswered well past their reply window"))
        }
        if let top = silence.max(by: { $0.score < $1.score }) { out.append(top) }

        // — cooling cluster (MAX within) —
        var cooling: [DecisionTrigger] = []
        if m.trajectory.kind == .cooling {
            cooling.append(.init(cluster: .cooling, kind: "trajectoryCooling",
                                 score: scoreTrajectoryCooling,
                                 evidence: m.trajectory.driver ?? "cooling off lately"))
        }
        if m.vibe.trend == .cooling {
            cooling.append(.init(cluster: .cooling, kind: "vibeCooling",
                                 score: scoreVibeCooling, evidence: "the vibe has cooled recently"))
        }
        if let top = cooling.max(by: { $0.score < $1.score }) { out.append(top) }

        // — effort cluster (independent; direction-checked inside EffortBalance) —
        if m.effort.lean == .theyUnderInvest {
            out.append(.init(cluster: .effort, kind: "effortImbalance",
                             score: scoreEffortImbalance,
                             evidence: "they've been putting in less lately"))
        }

        // — bid cluster (Gottman): the USER has been turning away from this
        //   person's bids for connection — a relational-erosion signal that
        //   reply-timing alone can't see. Direction: the user is under-tending,
        //   so a warmer re-engagement is the move. —
        if let rate = m.bids.turnTowardRate, rate < 0.5, !m.bids.isEmpty {
            out.append(.init(cluster: .bid, kind: "bidNeglect", score: scoreBidNeglect,
                             evidence: "turning toward only ~\(Int(rate * 100))% of their bids lately"))
        }

        // — sensitive tier: ONLY from a corroborated occasion about the actual
        //   participant. Heuristics can never produce this. —
        if let occ = m.sensitiveOccasion,
           occ.corroborationCount >= config.minSensitiveCorroboration,
           occ.subjectIsParticipant {
            out.append(.init(cluster: .sensitive, kind: occ.kind.rawValue,
                             score: scoreSensitive,
                             evidence: occ.evidence.joined(separator: "; ")))
        }

        return out
    }

    /// Which sensitive gesture kinds the evidence licenses. Corroborated
    /// occasions license the inferred kinds (loss→condolence, celebration→
    /// celebrate); an upcoming STORED birthday/anniversary licenses those.
    private static func allowedSensitiveKinds(_ m: RelationshipModel, now: Date,
                                              config: Config) -> Set<RelationshipDecision.GestureKind> {
        var allowed: Set<RelationshipDecision.GestureKind> = []
        if let occ = m.sensitiveOccasion,
           occ.corroborationCount >= config.minSensitiveCorroboration,
           occ.subjectIsParticipant {
            if occ.kind == .possibleLoss { allowed.insert(.condolence) }
            if occ.kind == .possibleCelebration { allowed.insert(.celebrate) }
        }
        for d in m.importantDates {
            guard let next = d.nextOccurrence(after: now),
                  next >= now, next.timeIntervalSince(now) <= config.dateHorizon else { continue }
            if d.kind == .birthday { allowed.insert(.birthday) }
            if d.kind == .anniversary { allowed.insert(.anniversary) }
        }
        return allowed
    }

    /// Cluster-aware total: MAX within each cluster, summed across clusters.
    static func clusterScore(_ triggers: [DecisionTrigger]) -> Int {
        var maxByCluster: [DecisionCluster: Int] = [:]
        for t in triggers {
            maxByCluster[t.cluster] = max(maxByCluster[t.cluster] ?? 0, t.score)
        }
        return maxByCluster.values.reduce(0, +)
    }

    /// Dedup key with a content-freshness component: any NEW inbound message
    /// (which advances lastMessageAt) busts the cache, so a fresh situation is
    /// never suppressed by a stale same-trigger-bucket decision.
    static func inputHash(_ m: RelationshipModel, triggers: [DecisionTrigger]) -> String {
        let kinds = triggers.map(\.kind).sorted().joined(separator: ",")
        let stamp = m.lastMessageAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "\(m.threadID.uuidString):\(kinds):\(stamp)"
    }
}
