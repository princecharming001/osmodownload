import Foundation
import OsmoCore

/// One person, fully composed: every deterministic read of the relationship
/// (who owes a reply, how they text, warming or cooling, their reply rhythm,
/// who's carrying the effort, the vibe trend), plus the durable layers the user
/// and the LLM have contributed (memory/goals, important dates, the last intel
/// pass). This is the single context object the Decision Engine reasons over —
/// assembled purely from data handed in, so it's testable without a store.
///
/// Nothing here decides anything. It gathers evidence and renders it; the
/// DecisionGate (deterministic scoring) and DecisionBrain (the LLM) are the ones
/// that decide, in a later phase.
public struct RelationshipModel: Equatable, Sendable {
    public var threadID: UUID
    public var personID: UUID?
    public var displayName: String
    public var isGroup: Bool

    // Deterministic core — the pure reads, each already honest about thin data.
    public var read: ThreadRead
    public var partner: PartnerProfile
    public var trajectory: Trajectory
    public var verdict: ReachOutVerdict
    public var rhythm: ResponseRhythm
    public var effort: EffortBalance
    public var vibe: VibeSeries
    /// Bids for connection — are their reaches being turned toward?
    public var bids: BidRead
    /// Attachment-flavored read: pursue/withdraw + whether they need space or
    /// reassurance. The lens that makes "reach out vs hold back" attuned to them.
    public var style: RelationalStyle

    // Cached LLM layer (nil until an intel pass has run for this thread).
    public var intel: ThreadIntel?

    // Durable, user/LLM-contributed layers.
    public var memory: RelationshipMemory?
    public var importantDates: [ImportantDate]
    /// A corroborated sensitive event (loss/celebration), set only by the
    /// LLM-confirmation pass — never by heuristics. The gate reads it to allow a
    /// sensitive-tier decision; nil the rest of the time.
    public var sensitiveOccasion: SensitiveOccasion?

    /// When the last message in the thread landed — the anchor for silence math.
    public var lastMessageAt: Date?
    /// If MY message is the last one and they READ it, when they read it — the
    /// thing that makes "left on read" actually mean left-on-read (a real read
    /// receipt), not just "unanswered". nil when they haven't read it or the last
    /// message is theirs.
    public var lastOutboundReadAt: Date?

    public static func assemble(
        threadID: UUID,
        displayName: String,
        isGroup: Bool,
        personID: UUID?,
        turns: [ThreadTurn],
        vibeSamples: [VibeSample] = [],
        importantDates: [ImportantDate] = [],
        memory: RelationshipMemory? = nil,
        intel: ThreadIntel? = nil,
        sensitiveOccasion: SensitiveOccasion? = nil,
        now: Date = Date()
    ) -> RelationshipModel {
        let read = ThreadRead.read(turns, now: now)
        let partner = PartnerProfile.read(turns)
        // "Left on read" needs a real read receipt: my message is last AND they read it.
        let lastTurn = turns.max(by: { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) })
        let lastOutboundReadAt = (lastTurn?.fromMe == true) ? lastTurn?.readAt : nil
        return RelationshipModel(
            threadID: threadID,
            personID: personID,
            displayName: displayName,
            isGroup: isGroup,
            read: read,
            partner: partner,
            trajectory: Trajectory.read(turns, now: now),
            verdict: ReachOutVerdict.decide(read: read, partner: partner, now: now),
            rhythm: ResponseRhythm.read(turns, now: now),
            effort: EffortBalance.read(turns),
            vibe: VibeSeries.read(vibeSamples, now: now),
            bids: BidDetector.read(turns, now: now),
            style: RelationalStyle.read(turns, now: now),
            intel: intel,
            memory: memory,
            importantDates: importantDates,
            sensitiveOccasion: sensitiveOccasion,
            lastMessageAt: turns.compactMap(\.sentAt).max(),
            lastOutboundReadAt: lastOutboundReadAt)
    }

    /// The evidence block the Decision Engine reads — compact, labelled, and
    /// silent about anything there isn't enough data to claim. Ordered
    /// most-actionable first. Never fabricates: an insufficient-data read simply
    /// contributes no line.
    public func decisionContext(now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("Person: \(displayName)\(isGroup ? " (group)" : "")")

        // Whose turn / the explicit reach-out read.
        switch read.ball {
        case .theirs: lines.append("Ball: they're waiting on you.")
        case .mine: lines.append("Ball: you sent last; it's on them.")
        case .empty: lines.append("Ball: no history yet.")
        }
        lines.append("Reach-out read: \(verdict.kind.rawValue) — \(verdict.headline)")

        // Trajectory.
        if trajectory.kind != .insufficient {
            var t = "Trajectory: \(trajectory.kind.rawValue)"
            if let d = trajectory.driver { t += " (\(d))" }
            lines.append(t)
        }

        // Rhythm — reply tempo + deliberation vs neglect + current silence.
        if !rhythm.isEmpty {
            if let med = rhythm.replyGapMedian {
                lines.append("Reply rhythm: typically ~\(Self.humanDuration(med)) to reply"
                    + (rhythm.replyGapP75.map { ", up to ~\(Self.humanDuration($0))" } ?? "") + ".")
            }
            if let read = rhythm.sendToReadMedian, let reply = rhythm.readToReplyMedian {
                lines.append("Attention: ~\(Self.humanDuration(read)) to read you, ~\(Self.humanDuration(reply)) to reply once read.")
            }
            switch rhythm.silence(sinceLastMessageAt: lastMessageAt, now: now) {
            case .unusual: lines.append("Silence: unusually long for them right now.")
            case .elevated: lines.append("Silence: a bit longer than their norm.")
            case .normal, .insufficient: break
            }
        }

        // Effort — only report when THEY are the one pulling back.
        if effort.lean == .theyUnderInvest {
            lines.append("Effort: they've been putting in less lately (shorter, less initiating).")
        }

        // Vibe trend.
        if vibe.trend == .cooling { lines.append("Vibe: cooling over the last couple of weeks.") }
        else if vibe.trend == .warming { lines.append("Vibe: warming lately.") }

        // Bids for connection (Gottman) — a reach that went unanswered, and the
        // longer-run turn-toward pattern.
        if bids.lastBidMissed {
            let what = bids.lastBidType.map { " (\($0.rawValue))" } ?? ""
            lines.append("Missed bid: their last message was a reach for connection\(what) that hasn't been met.")
        }
        if let rate = bids.turnTowardRate, rate < 0.5 {
            lines.append("Bid pattern: you've been turning toward only ~\(Int(rate * 100))% of their bids lately — the connection is being under-tended.")
        }

        // Attachment-flavored read — how to WEIGHT reaching out vs holding back.
        if let note = style.note {
            lines.append("How they relate: \(note).")
        }

        // Upcoming dates.
        let upcoming = importantDates
            .compactMap { d -> (ImportantDate, Date)? in
                d.nextOccurrence(after: now).map { (d, $0) }
            }
            .filter { $0.1.timeIntervalSince(now) <= 21 * 86_400 }
            .sorted { $0.1 < $1.1 }
        for (d, when) in upcoming.prefix(3) {
            let days = Int(when.timeIntervalSince(now) / 86_400)
            lines.append("Upcoming: \(d.label) in ~\(max(days, 0))d.")
        }

        // Open commitments the user made to them.
        if let commits = intel?.commitments, !commits.isEmpty {
            lines.append("You promised: \(commits.joined(separator: "; ")).")
        }

        // What the user has told Osmo about them.
        if let mem = memory, !mem.isEmpty {
            let ctx = mem.promptContext
            if !ctx.isEmpty { lines.append(ctx) }
        }

        return lines.joined(separator: "\n")
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
