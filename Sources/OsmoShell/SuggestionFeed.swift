import Foundation
import OsmoCore

/// One row in the proactive feed — the HUD's whole vocabulary. Derived from a
/// stored relationship-brain decision (or, later, folded together with queue
/// cards). Pure value type; the HUD renders it, the app maps decisions into it.
public struct BrainFeedItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case reachOut       // text them now
        case gesture        // something beyond a text
        case holdBack       // reassurance: deliberately wait
        case dateReminder   // an upcoming birthday/anniversary/deadline
    }
    public var id: String              // == the decision id (stable, dedupe key)
    public var threadID: UUID
    public var personID: UUID?
    public var displayName: String
    public var kind: Kind
    public var title: String           // the headline line
    public var detail: String?         // the supporting line (framing / why / move)
    public var isSensitive: Bool
    public var occasion: String?
    public var gestureKind: String?
    public var priority: Int

    public init(id: String, threadID: UUID, personID: UUID?, displayName: String,
                kind: Kind, title: String, detail: String?, isSensitive: Bool,
                occasion: String? = nil, gestureKind: String? = nil, priority: Int) {
        self.id = id; self.threadID = threadID; self.personID = personID
        self.displayName = displayName; self.kind = kind; self.title = title
        self.detail = detail; self.isSensitive = isSensitive; self.occasion = occasion
        self.gestureKind = gestureKind; self.priority = priority
    }
}

/// Builds the proactive feed from stored decisions. Pure + testable: the app
/// resolves display names and hands them in. Filters out `nothing` decisions
/// (persisted only for dedup), and terminal statuses (acted/dismissed/expired) —
/// only live decisions (fresh/surfaced) surface. One item per thread, ranked,
/// capped.
public enum SuggestionFeed {
    /// Rank by kind then confidence: a live reach-out/gesture outranks a
    /// hold-back reassurance; sensitive items float up within their kind.
    static func priority(_ d: StoredDecision) -> Int {
        let base: Int
        switch d.kind {
        case "reachOut": base = 300
        case "gesture": base = 250
        case "holdBack": base = 150
        default: base = 100
        }
        return base + (d.isSensitive ? 40 : 0) + Int((d.confidence * 20).rounded())
    }

    public static func build(decisions: [StoredDecision],
                             displayNames: [UUID: String],
                             cap: Int = 8) -> [BrainFeedItem] {
        var byThread: [UUID: BrainFeedItem] = [:]
        var bestPriority: [UUID: Int] = [:]

        for d in decisions {
            guard d.status == .fresh || d.status == .surfaced else { continue }
            guard let item = item(for: d, name: displayNames[d.threadID] ?? "Them") else { continue }
            // One per thread — keep the highest-priority.
            if let prev = bestPriority[d.threadID], prev >= item.priority { continue }
            bestPriority[d.threadID] = item.priority
            byThread[d.threadID] = item
        }

        return byThread.values
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority
                                                 : $0.threadID.uuidString < $1.threadID.uuidString }
            .prefix(cap)
            .map { $0 }
    }

    static func item(for d: StoredDecision, name: String) -> BrainFeedItem? {
        let p = priority(d)
        switch d.kind {
        case "reachOut":
            return BrainFeedItem(id: d.id, threadID: d.threadID, personID: d.personID,
                                 displayName: name, kind: .reachOut,
                                 title: "Reach out to \(name)", detail: d.move,
                                 isSensitive: d.isSensitive, priority: p)
        case "holdBack":
            let when = d.untilDays.map { " (~\($0)d)" } ?? ""
            return BrainFeedItem(id: d.id, threadID: d.threadID, personID: d.personID,
                                 displayName: name, kind: .holdBack,
                                 title: "Give \(name) space\(when)", detail: d.why,
                                 isSensitive: d.isSensitive, priority: p)
        case "gesture":
            return BrainFeedItem(id: d.id, threadID: d.threadID, personID: d.personID,
                                 displayName: name, kind: .gesture,
                                 title: gestureTitle(d.gestureKind, name: name),
                                 detail: d.move, isSensitive: d.isSensitive,
                                 occasion: d.occasion, gestureKind: d.gestureKind, priority: p)
        default:
            return nil   // "nothing" and unknowns never surface
        }
    }

    static func gestureTitle(_ kind: String?, name: String) -> String {
        switch kind {
        case "condolence": return "Check in on \(name)"
        case "celebrate": return "Celebrate with \(name)"
        case "birthday": return "\(name)'s birthday is coming up"
        case "anniversary": return "\(name)'s anniversary is coming up"
        case "sendFlowers": return "Consider flowers for \(name)"
        case "sendGift": return "Consider a gift for \(name)"
        case "offerMeal": return "Offer \(name) a meal"
        case "offerCall": return "Offer \(name) a call"
        case "offerHelp": return "Offer to help \(name)"
        case "planHangout": return "Make a plan with \(name)"
        case "visit": return "Consider visiting \(name)"
        case "repairRift": return "Mend things with \(name)"
        default: return "A gesture for \(name)"
        }
    }
}
