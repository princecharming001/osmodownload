import Foundation

/// Is this relationship warming, steady, or cooling? Compared honestly: THEIR
/// behavior over the recent two weeks vs their baseline over the prior eight —
/// message frequency, who initiates, and how fast they reply. Deterministic,
/// hysteresis-guarded (small wobbles read as steady), and silent when there
/// isn't enough history to say anything true.
public struct Trajectory: Equatable, Sendable {
    public enum Kind: String, Sendable { case warming, steady, cooling, insufficient }

    public var kind: Kind
    /// The single biggest driver, phrased for the UI ("they're replying twice as
    /// fast lately"). Nil when steady/insufficient.
    public var driver: String?

    static let recentWindow: TimeInterval = 14 * 86_400
    static let baselineWindow: TimeInterval = 56 * 86_400   // the 8 weeks before that

    public static func read(_ turns: [ThreadTurn], now: Date) -> Trajectory {
        let recentStart = now.addingTimeInterval(-recentWindow)
        let baselineStart = recentStart.addingTimeInterval(-baselineWindow)

        let dated = turns.filter { $0.sentAt != nil }
        let recent = dated.filter { $0.sentAt! >= recentStart && $0.sentAt! <= now }
        let baseline = dated.filter { $0.sentAt! >= baselineStart && $0.sentAt! < recentStart }

        let recentTheirs = recent.filter { !$0.fromMe }
        let baselineTheirs = baseline.filter { !$0.fromMe }
        // Minimum honesty bar: enough of THEIR messages in both windows.
        guard baselineTheirs.count >= 8, recentTheirs.count >= 3 else {
            return Trajectory(kind: .insufficient, driver: nil)
        }

        var score = 0
        var drivers: [(magnitude: Double, up: Bool, text: String)] = []

        // 1. Their message frequency (per week, window-normalized).
        let recentRate = Double(recentTheirs.count) / (recentWindow / 604_800)
        let baseRate = Double(baselineTheirs.count) / (baselineWindow / 604_800)
        if baseRate > 0 {
            let change = recentRate / baseRate
            if change >= 1.3 {
                score += 1
                drivers.append((change, true, "they're messaging noticeably more often lately"))
            } else if change <= 0.7 {
                score -= 1
                drivers.append((1 / change, false, "their messages have dropped off lately"))
            }
        }

        // 2. Their reply speed (median my-message → their-reply gap per window).
        let recentGap = PartnerProfile.medianReplyGap(recent.sorted { $0.sentAt! < $1.sentAt! })
        let baseGap = PartnerProfile.medianReplyGap(baseline.sorted { $0.sentAt! < $1.sentAt! })
        if let r = recentGap, let b = baseGap, b > 0 {
            let change = b / r   // >1 = faster now
            if change >= 1.5 {
                score += 1
                drivers.append((change, true, "they're replying faster than they used to"))
            } else if change <= 0.66 {
                score -= 1
                drivers.append((1 / change, false, "they're taking longer to reply than they used to"))
            }
        }

        // 3. Initiation balance: who breaks silences (>8h gaps). Their share up = investment.
        let recentInit = theirInitiationShare(recent)
        let baseInit = theirInitiationShare(baseline)
        if let r = recentInit, let b = baseInit {
            if r - b >= 0.25 {
                score += 1
                drivers.append((Double(r - b), true, "they've started reaching out first more"))
            } else if b - r >= 0.25 {
                score -= 1
                drivers.append((Double(b - r), false, "you've been the one starting most conversations lately"))
            }
        }

        let kind: Kind = score >= 1 ? .warming : score <= -1 ? .cooling : .steady
        let driver = kind == .steady ? nil
            : drivers.filter { $0.up == (kind == .warming) }
                .max(by: { $0.magnitude < $1.magnitude })?.text
        return Trajectory(kind: kind, driver: driver)
    }

    /// Share of conversation-openers (first message after >8h of silence) that
    /// were theirs. Nil when there were no openers in the window.
    static func theirInitiationShare(_ turns: [ThreadTurn]) -> Double? {
        let sorted = turns.filter { $0.sentAt != nil }.sorted { $0.sentAt! < $1.sentAt! }
        var openers: [Bool] = []   // true = theirs
        var prev: Date?
        for t in sorted {
            if let p = prev, t.sentAt!.timeIntervalSince(p) > 8 * 3600 {
                openers.append(!t.fromMe)
            }
            prev = t.sentAt
        }
        guard !openers.isEmpty else { return nil }
        return Double(openers.filter { $0 }.count) / Double(openers.count)
    }

}
