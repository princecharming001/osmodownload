import Foundation

/// Osmo's packaging, as pure logic. One metered thing converts: AI drafts.
/// Reading/search/inbox stay free forever (the honest hook — Osmo is useful
/// before it's paid); the *drafting brain* is the product.
///
/// Tiers:
///  - free: `freeDraftsPerWeek` AI drafts each week, then the paywall.
///  - trial: full Pro for `trialDays` from first activation.
///  - pro: unlimited.
///
/// All state is device-local (a purchase backend can swap in later); the
/// decisions are pure so they're unit-tested and the UI can't drift from them.
public enum Entitlements {
    public static let freeDraftsPerWeek = 15
    public static let trialDays = 14
    public static let proMonthlyPrice = "$24/mo"

    public enum Tier: String, Sendable, Equatable, Codable {
        case free, trial, pro
    }

    public struct State: Equatable, Sendable, Codable {
        public var tier: Tier
        /// When the trial started (nil = never started).
        public var trialStartedAt: Date?
        /// Drafts used in the current week window.
        public var draftsThisWeek: Int
        /// Start of the current metering week.
        public var weekStartedAt: Date

        public init(tier: Tier = .free, trialStartedAt: Date? = nil,
                    draftsThisWeek: Int = 0, weekStartedAt: Date = Date(timeIntervalSince1970: 0)) {
            self.tier = tier
            self.trialStartedAt = trialStartedAt
            self.draftsThisWeek = draftsThisWeek
            self.weekStartedAt = weekStartedAt
        }
    }

    public struct Decision: Equatable, Sendable {
        /// Whether this draft may run.
        public var allowed: Bool
        /// The state to persist after this decision (week rollover, count bump,
        /// trial expiry are all applied here).
        public var newState: State
        /// Drafts remaining this week (nil = unlimited).
        public var remaining: Int?
    }

    /// Decide one draft request. Applies trial expiry and week rollover, then
    /// meters free usage. Call with `consume: false` to peek without counting.
    public static func decideDraft(_ state: State, now: Date, consume: Bool = true) -> Decision {
        var s = state

        // Trial expiry: trial silently degrades to free when the window lapses.
        if s.tier == .trial, let started = s.trialStartedAt,
           now.timeIntervalSince(started) > Double(trialDays) * 86_400 {
            s.tier = .free
        }

        // Week rollover for the free meter.
        if now.timeIntervalSince(s.weekStartedAt) > 7 * 86_400 {
            s.weekStartedAt = now
            s.draftsThisWeek = 0
        }

        switch s.tier {
        case .pro, .trial:
            return Decision(allowed: true, newState: s, remaining: nil)
        case .free:
            let allowed = s.draftsThisWeek < freeDraftsPerWeek
            if allowed && consume { s.draftsThisWeek += 1 }
            return Decision(allowed: allowed, newState: s,
                            remaining: max(0, freeDraftsPerWeek - s.draftsThisWeek))
        }
    }

    /// Start the free trial (idempotent — restarting never extends it).
    public static func startTrial(_ state: State, now: Date) -> State {
        var s = state
        if s.trialStartedAt == nil { s.trialStartedAt = now }
        // Only upgrade if the (possibly old) trial window is still open.
        if let started = s.trialStartedAt,
           now.timeIntervalSince(started) <= Double(trialDays) * 86_400 {
            s.tier = .trial
        }
        return s
    }

    /// Days left in the trial (nil when not on trial).
    public static func trialDaysLeft(_ state: State, now: Date) -> Int? {
        guard state.tier == .trial, let started = state.trialStartedAt else { return nil }
        let left = Double(trialDays) - now.timeIntervalSince(started) / 86_400
        return max(0, Int(left.rounded(.up)))
    }
}
