import Foundation

/// Bids for connection — the most-validated construct in relationship science
/// (Gottman). A "bid" is any reach for attention/connection: a question, sharing
/// something personal, or an emotional disclosure. What matters is whether the
/// other person TURNS TOWARD it (engages), turns away (ignores/minimizes), or
/// turns against it (dismisses). Couples who turn toward bids ~86% of the time
/// stay together; ~33% split up. Osmo reads this for the USER: how often are you
/// turning toward THIS person's bids, and did their latest bid go unanswered?
/// That's a psychological signal reply-timing math alone can't see — someone can
/// reply fast and still turn away.
public struct BidRead: Equatable, Sendable {
    public enum BidType: String, Sendable { case question, sharing, emotional }
    /// Their most recent message was a bid for connection.
    public var lastWasBid: Bool
    public var lastBidType: BidType?
    /// That bid went unanswered or was met with a minimal/dismissive reply — a
    /// missed bid, the kind that quietly erodes a relationship.
    public var lastBidMissed: Bool
    /// Over the recent window, the share of THEIR bids the user turned toward
    /// (a substantive reply). nil below the sample floor. Low = you've been
    /// turning away — a relational-erosion signal worth acting on.
    public var turnTowardRate: Double?
    public var bidSampleCount: Int

    public var isEmpty: Bool { bidSampleCount < BidDetector.minSamples }
}

public enum BidDetector {
    static let minSamples = 4
    static let lookback: TimeInterval = 120 * 86_400
    /// Replies this short (or in the filler set) don't count as turning toward.
    static let minTurnTowardWords = 3
    static let filler: Set<String> = ["ok", "okay", "k", "kk", "lol", "haha", "hah",
        "nice", "cool", "yeah", "yep", "yup", "sure", "word", "same", "fr", "true", "👍", "👍🏻"]

    static let emotionalCues = ["excited", "nervous", "scared", "anxious", "sad", "proud",
        "happy", "stressed", "overwhelmed", "can't believe", "cant believe", "guess what",
        "finally", "so happy", "freaking out", "devastated", "heartbroken", "thrilled",
        "worried", "grateful", "miss you", "love you", "means a lot"]

    public static func read(_ turns: [ThreadTurn], now: Date = Date()) -> BidRead {
        let cutoff = now.addingTimeInterval(-lookback)
        let inWindow: (ThreadTurn) -> Bool = { turn in
            guard let at = turn.sentAt else { return false }
            return at >= cutoff && at <= now
        }
        let dated = turns.filter(inWindow).sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }

        var turnedToward = 0, totalBids = 0
        for i in dated.indices where !dated[i].fromMe {
            guard let type = bidType(dated[i].text) else { continue }
            _ = type
            totalBids += 1
            // The user turns toward if their NEXT message (before another of the
            // partner's) is substantive.
            if let next = dated[(i + 1)...].first, next.fromMe, isSubstantive(next.text) {
                turnedToward += 1
            }
        }

        let last = dated.last
        let lastType = last.flatMap { $0.fromMe ? nil : bidType($0.text) }
        let lastMissed: Bool = {
            guard let last, !last.fromMe, lastType != nil else { return false }
            // Nothing after it (unanswered) → missed. (A substantive reply would
            // have made it not the last turn.)
            return true
        }()

        return BidRead(
            lastWasBid: lastType != nil,
            lastBidType: lastType,
            lastBidMissed: lastMissed,
            turnTowardRate: totalBids >= minSamples ? Double(turnedToward) / Double(totalBids) : nil,
            bidSampleCount: totalBids)
    }

    static func bidType(_ text: String) -> BidRead.BidType? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard !isFiller(t) else { return nil }
        if t.contains("?") { return .question }
        if emotionalCues.contains(where: { lower.contains($0) }) { return .emotional }
        // Sharing: a substantive first-person statement about themselves.
        let words = t.split { $0 == " " || $0 == "\n" }.count
        let firstPerson = lower.contains("i ") || lower.hasPrefix("i'") || lower.contains(" my ")
            || lower.hasPrefix("my ") || lower.contains(" we ")
        if words >= 5, firstPerson { return .sharing }
        return nil
    }

    static func isSubstantive(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFiller(t) { return false }
        return t.split { $0 == " " || $0 == "\n" }.count >= minTurnTowardWords
    }

    static func isFiller(_ text: String) -> Bool {
        let stripped = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        return filler.contains(stripped)
    }
}
