import Foundation

/// The user's objective for a relationship (set in a Project). This is Osmo's
/// wedge — messages are drafted to *advance a goal you chose*, not just to reply.
/// `GoalKind` coarsely classifies the free-text goal so the engine can select the
/// apt psychology toolkit.
public enum GoalKind: String, Codable, Sendable, CaseIterable {
    case closeDeal          // move a sale/deal forward to yes
    case getMeeting         // secure a call/meeting/time
    case negotiate          // terms, price, scope, salary
    case professionalAsk    // raise, intro, reference, favor at work
    case askFavor           // a personal ask
    case rebuildTrust       // repair after a rupture
    case deescalate         // cool a tense/conflict thread
    case deepenBond         // grow closeness (friend/family/partner)
    case reconnect          // revive a dormant relationship
    case getDate            // romantic: secure/advance a date
    case maintainCadence    // keep a relationship warm over time
    case freeform           // user goal that doesn't map cleanly

    /// A short label for the "why this works" and project UI.
    public var label: String {
        switch self {
        case .closeDeal: return "close the deal"
        case .getMeeting: return "get the meeting"
        case .negotiate: return "negotiate"
        case .professionalAsk: return "make the ask"
        case .askFavor: return "ask a favor"
        case .rebuildTrust: return "rebuild trust"
        case .deescalate: return "cool things down"
        case .deepenBond: return "grow closer"
        case .reconnect: return "reconnect"
        case .getDate: return "get the date"
        case .maintainCadence: return "stay in touch"
        case .freeform: return "reach your goal"
        }
    }

    public static func classify(_ text: String?) -> GoalKind {
        guard let lower = text?.lowercased(), !lower.isEmpty else { return .freeform }
        for (kind, keys) in table {
            for k in keys where TextMatch.word(lower, k) { return kind }
        }
        return .freeform
    }

    // Priority-ordered; first hit wins.
    private static let table: [(GoalKind, [String])] = [
        (.rebuildTrust, ["rebuild trust", "repair", "make it right", "make amends",
                         "earn back", "fix things", "win back", "regain"]),
        (.deescalate, ["de-escalate", "deescalate", "cool", "calm", "defuse",
                       "stop fighting", "smooth over", "resolve the fight"]),
        (.closeDeal, ["close", "close the deal", "sign", "convert", "get them to buy",
                      "seal the deal", "win the deal", "get to yes"]),
        (.negotiate, ["negotiate", "negotiation", "raise", "salary", "price", "rate",
                      "terms", "discount", "counter", "counteroffer", "scope"]),
        (.getMeeting, ["meeting", "call", "book a", "get on a call", "schedule",
                       "hop on", "demo", "get time", "grab coffee"]),
        (.professionalAsk, ["reference", "referral", "intro", "introduction", "recommendation",
                            "endorse", "vouch", "promotion"]),
        (.getDate, ["date", "ask out", "second date", "first date", "take them out",
                    "get dinner", "see them again"]),
        (.reconnect, ["reconnect", "reach back out", "haven't talked", "havent talked",
                      "been a while", "rekindle", "revive", "back in touch"]),
        (.deepenBond, ["closer", "deepen", "strengthen", "bond", "grow the relationship",
                       "be there for", "support them", "show up"]),
        (.maintainCadence, ["stay in touch", "keep in touch", "check in regularly",
                            "keep warm", "stay top of mind", "nurture"]),
        (.askFavor, ["favor", "favour", "borrow", "help me", "need them to", "ask them to"])
    ]
}
