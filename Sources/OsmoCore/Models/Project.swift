import Foundation
import GRDB

/// A milestone on the way to a project's goal.
public struct Milestone: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var done: Bool
    public init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id; self.text = text; self.done = done
    }
}

public enum ProjectStatus: String, Codable, Sendable, CaseIterable {
    case active, achieved, stalled, archived
}

/// A goal-directed relationship — Osmo's wedge. The user sets a goal, tone,
/// boundaries, and context about themselves for one person (or, later, a cluster);
/// the brain drafts every message to advance it. Multiple projects can target the
/// same person. This is what makes Osmo "move each relationship where you want it"
/// rather than "clear your inbox."
public struct Project: Codable, Equatable, Sendable, Identifiable, SyncableRecord,
                       FetchableRecord, PersistableRecord {
    public var id: UUID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public var personID: UUID
    public var title: String
    public var goalText: String
    public var toneHint: String?
    public var boundaries: [String]        // JSON
    public var selfContext: String?
    public var milestones: [Milestone]     // JSON
    public var status: ProjectStatus
    public var createdAt: Date

    public static let databaseTableName = "project"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(id: UUID = UUID(), updatedAt: Date = Date(timeIntervalSince1970: 0),
                deviceSeq: Int64 = 0, deletedAt: Date? = nil,
                personID: UUID, title: String, goalText: String,
                toneHint: String? = nil, boundaries: [String] = [],
                selfContext: String? = nil, milestones: [Milestone] = [],
                status: ProjectStatus = .active, createdAt: Date = Date()) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
        self.personID = personID
        self.title = title
        self.goalText = goalText
        self.toneHint = toneHint
        self.boundaries = boundaries
        self.selfContext = selfContext
        self.milestones = milestones
        self.status = status
        self.createdAt = createdAt
    }
}
