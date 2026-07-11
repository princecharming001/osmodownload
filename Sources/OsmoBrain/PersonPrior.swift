import Foundation
import OsmoCore

/// What the brain has LEARNED about how to treat one person, from the outcomes
/// of past suggestions. Pure and deterministic — the app hands in the outcome
/// history, this derives the priors the gate and runner consult. Scoped per
/// TRIGGER FAMILY so ignoring noisy effort-nudges never silences a real birthday.
///
/// Design guards (from the critique):
///   • nudgeWeight mean-reverts toward a NEUTRAL 1.0 (absence ≠ distrust) with a
///     60-day half-life, and is CLAMPED to a floor so decay alone can never fully
///     silence a person — only an explicit quiet window can.
///   • Only outcomes the user actually SAW move the weight; expired-unseen is
///     neutral, so being away from the app never counts against a suggestion.
///   • suppressedGestureKinds needs repeated dismissals, and NEVER blacklists the
///     life-event kinds (condolence/birthday/anniversary) — those are too
///     important to category-mute from a couple of dismissals.
public struct PersonPrior: Equatable, Sendable {
    public var nudgeWeightByFamily: [String: Double]
    public var quietUntilByFamily: [String: Date]
    public var suppressedGestureKinds: Set<String>

    public func nudgeWeight(family: String) -> Double { nudgeWeightByFamily[family] ?? 1.0 }
    public func isQuiet(family: String, now: Date) -> Bool {
        (quietUntilByFamily[family] ?? .distantPast) > now
    }

    public struct Config: Sendable {
        public var actMultiplier = 1.15
        public var ignoreMultiplier = 0.8
        public var floor = 0.3
        public var ceil = 2.0
        public var halfLifeDays = 60.0
        public var quietAfterIgnores = 3
        public var quietDays = 14.0
        public var suppressGestureAfter = 2
        /// Never category-blacklist these — a wrong dismissal shouldn't mute a
        /// future real birthday/loss.
        public var neverSuppressedGestures: Set<String> = ["condolence", "birthday", "anniversary"]
        public init() {}
    }

    public static func from(_ outcomes: [SuggestionOutcome], now: Date,
                            config: Config = .init()) -> PersonPrior {
        var weight: [String: Double] = [:]
        var lastAt: [String: Date] = [:]
        var ignoreRun: [String: Int] = [:]
        var quietUntil: [String: Date] = [:]
        var gestureDismissals: [String: Int] = [:]

        // Chronological — the recurrence needs order.
        for o in outcomes.sorted(by: { $0.createdAt < $1.createdAt }) {
            let fam = o.family
            var w = weight[fam] ?? 1.0
            // Decay toward neutral for the time since the last outcome in this family.
            if let last = lastAt[fam] {
                let days = max(0, o.createdAt.timeIntervalSince(last) / 86_400)
                w = 1.0 + (w - 1.0) * pow(0.5, days / config.halfLifeDays)
            }
            switch o.outcome {
            case .acted:
                w *= config.actMultiplier
                ignoreRun[fam] = 0
            case .dismissedSeen, .ignoredSeen:
                w *= config.ignoreMultiplier
                let run = (ignoreRun[fam] ?? 0) + 1
                ignoreRun[fam] = run
                if o.outcome == .dismissedSeen, run >= config.quietAfterIgnores {
                    quietUntil[fam] = o.createdAt.addingTimeInterval(config.quietDays * 86_400)
                }
                if o.outcome == .dismissedSeen, let g = o.gestureKind {
                    gestureDismissals[g, default: 0] += 1
                }
            case .expiredUnseen:
                continue   // NEUTRAL — no weight change, no run advance
            }
            weight[fam] = min(config.ceil, max(config.floor, w))
            lastAt[fam] = o.createdAt
        }

        // Final decay toward neutral for the time from the last outcome to now.
        for (fam, last) in lastAt {
            let days = max(0, now.timeIntervalSince(last) / 86_400)
            let w = 1.0 + ((weight[fam] ?? 1.0) - 1.0) * pow(0.5, days / config.halfLifeDays)
            weight[fam] = min(config.ceil, max(config.floor, w))
        }

        let suppressed = Set(gestureDismissals
            .filter { $0.value >= config.suppressGestureAfter && !config.neverSuppressedGestures.contains($0.key) }
            .map(\.key))

        return PersonPrior(nudgeWeightByFamily: weight, quietUntilByFamily: quietUntil,
                           suppressedGestureKinds: suppressed)
    }
}

/// The global daily budget for how many decisions to bill the LLM for — scaled
/// by the trailing act-rate so a user who never acts isn't nagged, but with a
/// hard FLOOR so the brain can never spiral into total silence (and can recover
/// once the user starts acting again). Pure. Expired-unseen outcomes are excluded
/// from the act-rate (they're neutral, not rejections).
public enum DecisionBudget {
    public static func daily(_ outcomes: [SuggestionOutcome], now: Date,
                             floor: Int = 4, cap: Int = 20, noDataDefault: Int = 10) -> Int {
        let seen = outcomes.filter { $0.outcome != .expiredUnseen }
        guard !seen.isEmpty else { return noDataDefault }
        let acted = seen.filter { $0.outcome == .acted }.count
        let actRate = Double(acted) / Double(seen.count)
        return floor + Int((actRate * Double(cap - floor)).rounded())
    }
}
