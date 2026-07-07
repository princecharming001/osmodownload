import Foundation

/// The product's central promise, as one explicit call: reach out now, or lay
/// back? Decided from whose turn it is, how the current quiet compares to THEIR
/// reply rhythm, and whether the user is already carrying the thread. Pure —
/// same inputs, same verdict — and phrased to *reassure*, not nag.
public struct ReachOutVerdict: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case yourTurn      // they're waiting on you
        case giveItSpace   // quiet is normal for them — don't chase
        case layBack       // you've double-texted; let them come to you
        case goodTime      // well past their rhythm — a nudge lands as thoughtful
        case sayHi         // no history yet
    }

    public var kind: Kind
    /// Short chip text ("Worth a nudge").
    public var headline: String
    /// The honest why ("well past their usual ~4h · they're usually active evenings").
    public var detail: String?

    public static func decide(read: ThreadRead, partner: PartnerProfile,
                              now: Date) -> ReachOutVerdict {
        // Window hint appended to nudge advice when we know their active hours.
        func windowHint() -> String? {
            guard let block = partner.activeBlock else { return nil }
            let nowBlock = PartnerProfile.hourBlock(Calendar.current.component(.hour, from: now))
            return nowBlock == block ? nil : "best \(block)"
        }

        switch read.ball {
        case .empty:
            return ReachOutVerdict(kind: .sayHi, headline: "Say hi",
                                   detail: "No history yet — a light opener is all it takes.")
        case .theirs:
            return ReachOutVerdict(kind: .yourTurn, headline: "Your turn",
                                   detail: "They're waiting on you — reply beats perfect.")
        case .mine:
            let idle = read.idle ?? 0
            if let median = partner.medianReplySeconds, median > 0 {
                let ratio = idle / median
                if ratio >= 3, idle >= 86_400 {
                    let parts = ["well past their usual ~\(PartnerProfile.humanGap(median))",
                                 windowHint()].compactMap { $0 }
                    return ReachOutVerdict(kind: .goodTime, headline: "Worth a nudge",
                                           detail: parts.joined(separator: " · "))
                }
                if read.userCarrying {
                    return ReachOutVerdict(kind: .layBack, headline: "Lay back",
                                           detail: "You've sent the last two — let them come to you.")
                }
                return ReachOutVerdict(kind: .giveItSpace, headline: "Give it space",
                                       detail: "They usually take ~\(PartnerProfile.humanGap(median)) — this quiet is normal.")
            }
            // No rhythm data: conservative fixed thresholds.
            if idle >= 3 * 86_400 {
                let parts = ["quiet ~\(Int(idle / 86_400)) days", windowHint()].compactMap { $0 }
                return ReachOutVerdict(kind: .goodTime, headline: "Worth a nudge",
                                       detail: parts.joined(separator: " · "))
            }
            if read.userCarrying {
                return ReachOutVerdict(kind: .layBack, headline: "Lay back",
                                       detail: "You've sent the last two — let them come to you.")
            }
            return ReachOutVerdict(kind: .giveItSpace, headline: "Give it space",
                                   detail: "Nothing here reads as a problem yet.")
        }
    }
}
