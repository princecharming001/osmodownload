import Foundation

/// Who's carrying the relationship — measured symmetrically but reported with a
/// DIRECTION, because the two directions mean opposite things. When THEY
/// under-invest (they stopped initiating, stopped asking about you, went terse),
/// that's a signal worth a gentle reach-out. When YOU under-invest, that's not a
/// "reach out" nudge at all — it's already the reply/leftOnRead lane's job, and
/// surfacing it as a reach-out candidate would double-count and contradict the
/// queue. So the trigger only fires on `.theyUnderInvest`; `.iUnderInvest` and
/// `.balanced` never do. Pure and deterministic.
public struct EffortBalance: Equatable, Sendable {
    /// Share of conversation-openers that were theirs (0…1). nil if no openers.
    public var theirInitiationShare: Double?
    /// Share of all questions asked that were theirs (0…1). nil if none asked.
    public var theirQuestionShare: Double?
    /// Share of total words that were theirs (0…1). nil if empty.
    public var theirWordShare: Double?
    /// Times I sent 2+ in a row with no reply from them (my unanswered reaching).
    public var myUnansweredDoubleTexts: Int
    /// Times they sent 2+ in a row with no reply from me (their unanswered reaching).
    public var theirUnansweredDoubleTexts: Int
    /// Their messages in-window — the honesty basis.
    public var sampleCount: Int

    public var isEmpty: Bool { sampleCount < EffortBalance.minSamples }

    static let minSamples = 6   // effort claims need more than a couple of turns
    /// A share this far below parity (0.5) counts as under-investment on that axis.
    static let leanThreshold = 0.18

    public enum Lean: String, Sendable {
        case balanced          // no meaningful imbalance
        case theyUnderInvest   // they've pulled back — a reach-out can land as thoughtful
        case iUnderInvest      // I've pulled back — the reply/leftOnRead lane owns this, not a nudge
        case insufficient
    }

    /// The signed direction. Averages the axes that have data; a positive net
    /// (they're below parity) reads as them under-investing. Double-texts break
    /// ties: my unanswered reaching means THEY went quiet (they under-invest);
    /// their unanswered reaching means I went quiet (I under-invest).
    public var lean: Lean {
        guard !isEmpty else { return .insufficient }
        var deficits: [Double] = []   // >0 = them below parity on this axis
        if let s = theirInitiationShare { deficits.append(0.5 - s) }
        if let s = theirQuestionShare { deficits.append(0.5 - s) }
        if let s = theirWordShare { deficits.append(0.5 - s) }
        guard let net = Stats.mean(deficits) else { return .insufficient }

        // Double-text asymmetry nudges the reading toward whoever is doing the
        // unanswered reaching (they're the one still investing).
        let doubleTextTilt = Double(myUnansweredDoubleTexts - theirUnansweredDoubleTexts) * 0.02
        let signal = net + doubleTextTilt

        if signal >= EffortBalance.leanThreshold { return .theyUnderInvest }
        if signal <= -EffortBalance.leanThreshold { return .iUnderInvest }
        return .balanced
    }

    public static func read(_ turns: [ThreadTurn]) -> EffortBalance {
        let dated = turns.filter { $0.sentAt != nil }.sorted { $0.sentAt! < $1.sentAt! }
        let theirs = dated.filter { !$0.fromMe }

        // Word share.
        func wordCount(_ text: String) -> Int {
            text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        }
        func sumWords(_ ts: [ThreadTurn]) -> Int {
            var sum = 0
            for t in ts { sum += wordCount(t.text) }
            return sum
        }
        let theirWords = sumWords(theirs)
        let allWords = sumWords(dated)
        let wordShare = allWords > 0 ? Double(theirWords) / Double(allWords) : nil

        // Question share.
        let theirQ = theirs.filter { $0.text.contains("?") }.count
        let myQ = dated.filter { $0.fromMe && $0.text.contains("?") }.count
        let totalQ = theirQ + myQ
        let questionShare = totalQ > 0 ? Double(theirQ) / Double(totalQ) : nil

        // Unanswered double-texts: runs of 2+ consecutive same-sender messages
        // that were never answered by the other side.
        var (myDoubles, theirDoubles) = (0, 0)
        var runOwner: Bool? = nil   // true = mine
        var runLen = 0
        var answered = true
        func closeRun() {
            if runLen >= 2, !answered {
                if runOwner == true { myDoubles += 1 } else if runOwner == false { theirDoubles += 1 }
            }
        }
        for t in dated {
            if runOwner == t.fromMe {
                runLen += 1
            } else {
                closeRun()
                runOwner = t.fromMe
                runLen = 1
                answered = false
            }
            // The moment the other side speaks, the prior run WAS answered —
            // handled by the owner-switch above resetting `answered=false` for
            // the new run; the closed run only counts if it stayed unanswered.
        }
        closeRun()

        return EffortBalance(
            theirInitiationShare: Trajectory.theirInitiationShare(dated),
            theirQuestionShare: questionShare,
            theirWordShare: wordShare,
            myUnansweredDoubleTexts: myDoubles,
            theirUnansweredDoubleTexts: theirDoubles,
            sampleCount: theirs.count)
    }
}
