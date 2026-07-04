import Foundation
import GRDB

/// One durable thing Osmo knows about a person — a fact, a preference, an inside
/// joke, or a do/don't rule. Accumulates over time from what the user tells Osmo
/// and what it distills from real threads.
public struct MemoryFact: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case fact           // "their dog is named Biscuit"
        case preference     // "hates phone calls, texts back fast"
        case insideJoke     // "the 'corn' bit"
        case doRule         // "always ask about her mom"
        case dontRule       // "never bring up his startup that failed"
    }
    public var id: UUID
    public var kind: Kind
    public var text: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), kind: Kind = .fact, text: String, updatedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.updatedAt = updatedAt
    }
}

/// Durable per-person memory (one row per identity-graph person). The `note` is
/// the freeform "what's going on lately"; `facts` accumulate typed; `summary` is
/// an optional model-produced rolling summary. `promptContext` renders the block
/// the brain injects. The record `id` equals the `personID` (one memory per
/// person → natural upsert).
public struct RelationshipMemory: Codable, Equatable, Sendable, Identifiable, SyncableRecord,
                                  FetchableRecord, PersistableRecord {
    public var id: UUID              // == personID
    public var updatedAt: Date
    public var deviceSeq: Int64
    public var deletedAt: Date?

    public var note: String
    public var facts: [MemoryFact]   // stored as JSON
    public var summary: String?

    public static let databaseTableName = "relationship_memory"

    public var sync: SyncMeta {
        get { SyncMeta(id: id, updatedAt: updatedAt, deviceSeq: deviceSeq, deletedAt: deletedAt) }
        set { id = newValue.id; updatedAt = newValue.updatedAt
              deviceSeq = newValue.deviceSeq; deletedAt = newValue.deletedAt }
    }

    public init(personID: UUID, updatedAt: Date = Date(timeIntervalSince1970: 0),
                deviceSeq: Int64 = 0, deletedAt: Date? = nil,
                note: String = "", facts: [MemoryFact] = [], summary: String? = nil) {
        self.id = personID
        self.updatedAt = updatedAt
        self.deviceSeq = deviceSeq
        self.deletedAt = deletedAt
        self.note = note
        self.facts = facts
        self.summary = summary
    }

    public var personID: UUID { id }

    public var isEmpty: Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && facts.isEmpty
            && (summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public mutating func addFact(_ text: String, kind: MemoryFact.Kind = .fact,
                                 now: Date = Date(), limit: Int = 100) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        facts.removeAll { $0.kind == kind && $0.text.lowercased() == trimmed.lowercased() }
        facts.append(MemoryFact(kind: kind, text: trimmed, updatedAt: now))
        if facts.count > limit {
            facts = Array(facts.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
        }
    }

    /// The block injected into the brain's prompt (empty when nothing is known).
    public var promptContext: String {
        var lines: [String] = []
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Where things stand: \(summary.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { lines.append("Lately: \(n)") }
        func group(_ kind: MemoryFact.Kind, _ label: String) {
            let items = facts.filter { $0.kind == kind }.map(\.text)
            if !items.isEmpty { lines.append("\(label): \(items.joined(separator: "; "))") }
        }
        group(.doRule, "Always")
        group(.dontRule, "Never")
        group(.preference, "They prefer")
        group(.insideJoke, "Inside jokes")
        group(.fact, "Remember")
        return lines.joined(separator: "\n")
    }
}
