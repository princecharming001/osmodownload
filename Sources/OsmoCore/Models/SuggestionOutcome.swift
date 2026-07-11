import Foundation
import GRDB

/// What became of a surfaced suggestion — the raw material the learning loop
/// reads. Device-local telemetry. Only outcomes for decisions the user actually
/// SAW count as signal; an expired-unseen decision is recorded as `.expiredUnseen`
/// and treated as NEUTRAL (never a rejection), so a weekend away from the app
/// can't silence the brain.
public enum OutcomeKind: String, Codable, Sendable {
    case acted            // positive — the user acted on it
    case dismissedSeen    // real negative — dismissed after a confirmed impression
    case expiredUnseen    // NEUTRAL — TTL ran out with no impression
    case ignoredSeen      // soft negative — seen, not acted, aged out
}

public struct SuggestionOutcome: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var decisionID: String
    public var threadID: UUID
    public var personID: UUID?
    /// The decision kind ("reachOut"/"holdBack"/"gesture").
    public var decisionKind: String
    /// The gesture kind when applicable (for per-gesture suppression).
    public var gestureKind: String?
    /// The dominant trigger family ("date"/"promise"/"silence"/"cooling"/"effort"/
    /// "sensitive") — learning is scoped per family so ignoring noisy nudges
    /// never suppresses an unrelated high-value one.
    public var family: String
    public var outcome: OutcomeKind
    public var createdAt: Date

    public static let databaseTableName = "suggestion_outcome"

    public init(id: Int64? = nil, decisionID: String, threadID: UUID, personID: UUID? = nil,
                decisionKind: String, gestureKind: String? = nil, family: String,
                outcome: OutcomeKind, createdAt: Date = Date()) {
        self.id = id; self.decisionID = decisionID; self.threadID = threadID
        self.personID = personID; self.decisionKind = decisionKind; self.gestureKind = gestureKind
        self.family = family; self.outcome = outcome; self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
