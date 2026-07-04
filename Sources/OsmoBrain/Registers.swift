import Foundation

/// Where a relationship sits on the spectrum. Drives register (formality/warmth),
/// which psychology techniques are apt, and which guardrails apply. Inferred from
/// the free-text relationship label the user set, or from context. This is the
/// "relationship-spectrum aware, not wedge-locked" requirement — one engine that
/// adapts from boss to crush.
public enum RelationshipRegister: String, Codable, Sendable, CaseIterable {
    case boss, manager, report, coworker, client, investor, recruiter, vendor
    case friend, bestFriend, acquaintance
    case parent, sibling, family
    case partner, crush, situationship, ex
    case unknown

    /// 0 = maximally casual, 1 = maximally formal. Sets baseline register.
    public var formality: Double {
        switch self {
        case .investor, .recruiter, .client, .vendor: return 0.85
        case .boss, .manager: return 0.7
        case .coworker, .report: return 0.55
        case .acquaintance: return 0.5
        case .parent, .family: return 0.4
        case .friend, .sibling: return 0.25
        case .partner: return 0.2
        case .bestFriend, .crush, .situationship: return 0.15
        case .ex: return 0.45          // measured, boundaried
        case .unknown: return 0.5
        }
    }

    /// Whether emoji read as natural here by default (the user's own habits override).
    public var emojiNaturalByDefault: Bool {
        switch self {
        case .boss, .manager, .investor, .recruiter, .client, .vendor: return false
        default: return true
        }
    }

    /// A one-line register directive injected into the prompt.
    public var guidance: String {
        switch self {
        case .boss, .manager:
            return "Register: professional-warm — brief, confident, own outcomes, no over-apologizing, no emoji unless they use them first."
        case .report:
            return "Register: supportive-lead — clear, encouraging, specific; you set direction without stiffness."
        case .coworker:
            return "Register: friendly-professional — casual is fine, keep it efficient."
        case .client, .vendor:
            return "Register: professional — clear and warm, zero slang, answer every ask explicitly."
        case .investor:
            return "Register: crisp-confident — lead with the signal or the number, no hype, no filler."
        case .recruiter:
            return "Register: polished-approachable — enthusiastic but precise, no desperation."
        case .friend:
            return "Register: casual — relaxed and real; formality reads distant."
        case .bestFriend:
            return "Register: inner-circle — shorthand, humor, zero formality."
        case .acquaintance:
            return "Register: warm-light — friendly, a little more complete than with close friends."
        case .parent, .family:
            return "Register: family-warm — answer their actual question, add one small life detail; slightly fuller sentences."
        case .sibling:
            return "Register: familiar-blunt — teasing is affection, skip the pleasantries."
        case .partner:
            return "Register: intimate — affection direct, shorthand and in-jokes welcome, never corporate."
        case .crush, .situationship:
            return "Register: light and confident — playful over eager; don't over-invest per message."
        case .ex:
            return "Register: measured — kind, boundaried, no late-night energy."
        case .unknown:
            return "Register: neutral-warm — friendly and clear until you learn their style."
        }
    }

    /// Longest-keyword match from a free-text label ("my boss", "gf", "college roommate").
    public static func infer(from label: String) -> RelationshipRegister {
        let lower = label.lowercased()
        var best: (len: Int, reg: RelationshipRegister)?
        for (key, reg) in keywordTable {
            guard wordMatch(lower, key) else { continue }
            if best == nil || key.count > best!.len { best = (key.count, reg) }
        }
        return best?.reg ?? .unknown
    }

    private static let keywordTable: [(String, RelationshipRegister)] = [
        ("boss", .boss), ("manager", .manager), ("supervisor", .boss), ("ceo", .boss),
        ("direct report", .report), ("report", .report), ("mentee", .report),
        ("coworker", .coworker), ("co-worker", .coworker), ("colleague", .coworker),
        ("teammate", .coworker), ("client", .client), ("customer", .client),
        ("investor", .investor), ("vc", .investor), ("angel", .investor),
        ("recruiter", .recruiter), ("hiring manager", .recruiter),
        ("vendor", .vendor), ("supplier", .vendor),
        ("best friend", .bestFriend), ("bestie", .bestFriend), ("bff", .bestFriend),
        ("friend", .friend), ("buddy", .friend), ("roommate", .friend), ("flatmate", .friend),
        ("acquaintance", .acquaintance), ("contact", .acquaintance),
        ("mom", .parent), ("mother", .parent), ("dad", .parent), ("father", .parent),
        ("parent", .parent), ("grandma", .family), ("grandpa", .family),
        ("brother", .sibling), ("sister", .sibling), ("sibling", .sibling),
        ("cousin", .family), ("aunt", .family), ("uncle", .family), ("family", .family),
        ("girlfriend", .partner), ("boyfriend", .partner), ("partner", .partner),
        ("wife", .partner), ("husband", .partner), ("gf", .partner), ("bf", .partner),
        ("fiance", .partner), ("fiancé", .partner), ("fiancée", .partner), ("spouse", .partner),
        ("crush", .crush), ("date", .crush),
        ("situationship", .situationship), ("talking stage", .situationship), ("talking to", .situationship),
        ("ex", .ex)
    ]

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func wordMatch(_ haystack: String, _ needle: String) -> Bool {
        guard let range = haystack.range(of: needle) else { return false }
        let before = range.lowerBound == haystack.startIndex ? nil
            : haystack[haystack.index(before: range.lowerBound)]
        let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
        let beforeOK = before.map { !isWordChar($0) } ?? true
        let afterOK = after.map { !isWordChar($0) } ?? true
        return beforeOK && afterOK
    }
}
