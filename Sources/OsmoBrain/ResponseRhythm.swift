import Foundation

/// The tempo of a relationship, read honestly from THEIR behavior: how long
/// they take to reply (a distribution, not a single median), and — where the
/// platform exposes read receipts — the difference between how long they take
/// to *read* you versus how long they take to *reply once they've read*
/// (deliberation vs neglect). Silence is judged against THEIR OWN rhythm, so a
/// friend who always takes three days never reads as "unusually quiet" at three
/// days. Pure, deterministic, and silent below a sample floor.
///
/// v1 bounds the lookback to a recent window rather than modelling full
/// recent-vs-baseline rhythm drift (that's a v2 refinement) — but never blends
/// a person's ancient rhythm into today's percentiles, which was the real trap.
public struct ResponseRhythm: Equatable, Sendable {
    /// Their reply-gap distribution (my message → their reply), seconds.
    public var replyGapP25: TimeInterval?
    public var replyGapMedian: TimeInterval?
    public var replyGapP75: TimeInterval?
    /// My message → they read it (deliberation window). Only where receipts exist.
    public var sendToReadMedian: TimeInterval?
    /// They read it → they reply (attention once seen — the "neglect" tell).
    public var readToReplyMedian: TimeInterval?
    /// Number of reply gaps that cleared the noise filter — the honesty basis.
    public var sampleCount: Int

    /// Not enough of their replies in-window to say anything true about tempo.
    public var isEmpty: Bool { sampleCount < ResponseRhythm.minSamples }

    /// Mirrors the house sample floor (PartnerProfile requires >= 3).
    static let minSamples = 3
    /// Only reply gaps between 30s and 7d count as "reply tempo" — instant
    /// double-texts and multi-week gaps aren't tempo (matches medianReplyGap).
    static let minGap: TimeInterval = 30
    static let maxGap: TimeInterval = 7 * 86_400
    /// Bound the lookback so ancient rhythm never pollutes current percentiles.
    static let lookback: TimeInterval = 120 * 86_400

    public static func read(_ turns: [ThreadTurn], now: Date = Date()) -> ResponseRhythm {
        let cutoff = now.addingTimeInterval(-lookback)
        let inWindow: (ThreadTurn) -> Bool = { turn in
            guard let at = turn.sentAt else { return false }
            return at >= cutoff && at <= now
        }
        let dated = turns.filter(inWindow).sorted { $0.sentAt! < $1.sentAt! }

        var replyGaps: [TimeInterval] = []
        var sendToRead: [TimeInterval] = []
        var readToReply: [TimeInterval] = []

        for i in 1..<max(dated.count, 1) {
            let prev = dated[i - 1], cur = dated[i]
            // Their reply to my message.
            if prev.fromMe, !cur.fromMe, let a = prev.sentAt, let b = cur.sentAt {
                let gap = b.timeIntervalSince(a)
                if gap > minGap, gap < maxGap { replyGaps.append(gap) }
                // Split that gap into deliberation (send→read) + attention
                // (read→reply) when the read receipt is present and sane.
                if let read = prev.readAt {
                    let toRead = read.timeIntervalSince(a)
                    let toReply = b.timeIntervalSince(read)
                    if toRead >= 0, toRead < maxGap { sendToRead.append(toRead) }
                    if toReply >= 0, toReply < maxGap { readToReply.append(toReply) }
                }
            }
        }

        return ResponseRhythm(
            replyGapP25: Stats.percentile(replyGaps, 0.25, minCount: minSamples),
            replyGapMedian: Stats.percentile(replyGaps, 0.50, minCount: minSamples),
            replyGapP75: Stats.percentile(replyGaps, 0.75, minCount: minSamples),
            sendToReadMedian: Stats.median(sendToRead, minCount: minSamples),
            readToReplyMedian: Stats.median(readToReply, minCount: minSamples),
            sampleCount: replyGaps.count)
    }

    /// How unusual the current gap is relative to THEIR OWN reply rhythm.
    /// `.insufficient` below the sample floor — never guess. A slow replier's
    /// normal cadence reads as `.normal`; only a gap well past their own p75
    /// escalates.
    public enum Silence: String, Sendable { case normal, elevated, unusual, insufficient }

    /// Judge the gap since `lastMessageAt` (usually their last message, or my
    /// last if I'm waiting on a read-but-unanswered) against their p75.
    public func silence(sinceLastMessageAt lastMessageAt: Date?, now: Date) -> Silence {
        guard !isEmpty, let p75 = replyGapP75, let last = lastMessageAt else { return .insufficient }
        let idle = now.timeIntervalSince(last)
        if idle <= p75 { return .normal }
        if idle <= 2 * p75 { return .elevated }
        return .unusual
    }
}
