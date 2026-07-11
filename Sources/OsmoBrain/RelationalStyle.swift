import Foundation

/// How this person RELATES — an attachment-flavored read inferred from behavior,
/// not a label they picked. The single most useful thing for deciding whether to
/// reach out or hold back: the SAME silence means opposite things depending on
/// the person. Someone who pulls back and replies slowly (avoidant-leaning) needs
/// SPACE — chasing them harder backfires. Someone who re-initiates and replies
/// fast (anxious-leaning) reads silence as distance and a warm check-in lands.
/// Osmo reads pursue-vs-withdraw and the resulting space-need so the decision is
/// attuned to THIS person, not a one-size-fits-all rhythm rule.
public struct RelationalStyle: Equatable, Sendable {
    public enum Tendency: String, Sendable { case pursues, withdraws, mutual, unknown }
    public enum SpaceNeed: String, Sendable { case space, reassurance, neutral, unknown }

    public var tendency: Tendency
    public var spaceNeed: SpaceNeed
    /// A one-line read for the decision prompt / UI — never fabricated (unknown
    /// when there isn't enough history).
    public var note: String?

    public static func read(_ turns: [ThreadTurn], now: Date = Date()) -> RelationalStyle {
        let dated = turns.filter { $0.sentAt != nil }
        let initShare = Trajectory.theirInitiationShare(dated)
        let rhythm = ResponseRhythm.read(turns, now: now)

        guard let initShare, !rhythm.isEmpty else {
            return RelationalStyle(tendency: .unknown, spaceNeed: .unknown, note: nil)
        }

        let tendency: Tendency = initShare >= 0.6 ? .pursues
                               : initShare <= 0.4 ? .withdraws : .mutual
        let repliesFast = (rhythm.replyGapMedian ?? .greatestFiniteMagnitude) < 4 * 3600

        let spaceNeed: SpaceNeed
        switch tendency {
        case .withdraws:
            spaceNeed = .space
        case .pursues:
            spaceNeed = repliesFast ? .reassurance : .neutral
        case .mutual, .unknown:
            spaceNeed = .neutral
        }

        let note: String?
        switch spaceNeed {
        case .space:
            note = "tends to pull back and take their time — pushing harder tends to backfire; space reads as respect"
        case .reassurance:
            note = "re-initiates and replies quickly — silence can read to them as distance, so a warm check-in lands well"
        case .neutral, .unknown:
            note = nil
        }

        return RelationalStyle(tendency: tendency, spaceNeed: spaceNeed, note: note)
    }
}
