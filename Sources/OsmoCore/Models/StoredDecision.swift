import Foundation
import GRDB

public enum StoredDecisionStatus: String, Codable, Sendable {
    case fresh       // computed, not yet shown
    case surfaced    // rendered on screen (a real impression — required before any negative signal)
    case acted       // the user acted on it
    case dismissed   // the user dismissed it after seeing it
    case expired     // its TTL ran out unseen (NEUTRAL — never counts as a negative)
}

/// A persisted relationship-brain decision. In shadow mode these are written and
/// inspected but never surfaced; once the HUD ships they drive the feed. The
/// flattened shape mirrors OsmoBrain's `RelationshipDecision` (which OsmoCore
/// can't import — that's the App layer's mapping job). Device-local UX state.
public struct StoredDecision: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String            // deterministic: "<threadID>:<inputHash>"
    public var threadID: UUID
    public var personID: UUID?
    /// "reachOut" | "holdBack" | "gesture" | "nothing".
    public var kind: String
    /// reachOut → the move; gesture → the framing.
    public var move: String?
    public var gestureKind: String?  // when kind == "gesture"
    public var occasion: String?
    public var untilDays: Int?       // holdBack horizon
    public var why: String?          // holdBack reassurance
    public var confidence: Double
    public var evidence: [String]    // stored as JSON
    public var inputHash: String
    public var isSensitive: Bool
    public var status: StoredDecisionStatus
    public var createdAt: Date
    public var expiresAt: Date

    public static let databaseTableName = "relationship_decision"

    public init(id: String, threadID: UUID, personID: UUID? = nil, kind: String,
                move: String? = nil, gestureKind: String? = nil, occasion: String? = nil,
                untilDays: Int? = nil, why: String? = nil, confidence: Double,
                evidence: [String] = [], inputHash: String, isSensitive: Bool,
                status: StoredDecisionStatus = .fresh, createdAt: Date = Date(),
                expiresAt: Date) {
        self.id = id
        self.threadID = threadID
        self.personID = personID
        self.kind = kind
        self.move = move
        self.gestureKind = gestureKind
        self.occasion = occasion
        self.untilDays = untilDays
        self.why = why
        self.confidence = confidence
        self.evidence = evidence
        self.inputHash = inputHash
        self.isSensitive = isSensitive
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public static func makeID(threadID: UUID, inputHash: String) -> String {
        "\(threadID.uuidString):\(inputHash)"
    }
}
