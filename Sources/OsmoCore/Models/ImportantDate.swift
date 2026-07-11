import Foundation
import GRDB

public enum ImportantDateKind: String, Codable, Sendable {
    case birthday, anniversary, deadline, promise, event
}

/// How this date came to be known — a keyword hit (weakest), an LLM intel pass,
/// or a user typing it in (strongest). Sensitive-gesture decisions must never
/// rest on `.regex` alone (see OccasionDetector) — the source is carried so the
/// decision engine can enforce that.
public enum ImportantDateSource: String, Codable, Sendable {
    case regex, intel, manual
}

/// A date worth remembering for a relationship: birthdays/anniversaries
/// (recurring, month/day without a year), deadlines, and promises. Deduped by a
/// deterministic `id` so the same birthday captured twice is one row.
/// Device-local UX state — no sync columns.
public struct ImportantDate: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var threadID: UUID
    public var personID: UUID?
    public var kind: ImportantDateKind
    /// Human label, e.g. "Sarah's birthday" or "grant deadline".
    public var label: String
    /// Concrete date when known (deadlines, promises with a due date).
    public var date: Date?
    /// For recurring dates without a fixed year (birthdays/anniversaries).
    public var month: Int?
    public var day: Int?
    public var recurring: Bool
    public var source: ImportantDateSource
    /// The matched phrase / user note — evidence, never surfaced raw.
    public var evidence: String?
    public var createdAt: Date

    public static let databaseTableName = "important_date"

    public init(id: String, threadID: UUID, personID: UUID? = nil,
                kind: ImportantDateKind, label: String, date: Date? = nil,
                month: Int? = nil, day: Int? = nil, recurring: Bool = false,
                source: ImportantDateSource, evidence: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.threadID = threadID
        self.personID = personID
        self.kind = kind
        self.label = label
        self.date = date
        self.month = month
        self.day = day
        self.recurring = recurring
        self.source = source
        self.evidence = evidence
        self.createdAt = createdAt
    }

    /// Deterministic dedupe key. Recurring dates key on month/day (a birthday is
    /// the same fact every year); one-off dates key on the ISO day.
    public static func makeID(threadID: UUID, kind: ImportantDateKind,
                              date: Date?, month: Int?, day: Int?) -> String {
        let suffix: String
        if let m = month, let d = day {
            suffix = "\(m)-\(d)"
        } else if let date {
            suffix = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: date))
        } else {
            suffix = "nodate"
        }
        return "\(threadID.uuidString):\(kind.rawValue):\(suffix)"
    }
}
