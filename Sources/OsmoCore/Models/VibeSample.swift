import Foundation
import GRDB

/// Where a vibe reading came from — the LLM's already-paid-for temperature
/// judgment, or the deterministic keyword sentiment that runs even on dormant
/// threads intel never touches.
public enum VibeSource: String, Codable, Sendable {
    case llmTemperature
    case keywordSentiment
}

/// One point-in-time reading of a thread's emotional temperature, persisted as
/// a time series (`vibe_sample`) so the brain can see a relationship warming or
/// cooling over WEEKS rather than judging only the latest message.
/// Device-local telemetry — no sync columns; a redeploy/reinstall simply starts
/// a fresh series (cross-device propagation is a v2 concern).
public struct VibeSample: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var threadID: UUID
    public var sampledAt: Date
    /// Normalized emotional temperature, -1 (cool) … +1 (warm).
    public var score: Double
    public var source: VibeSource

    public static let databaseTableName = "vibe_sample"

    public init(id: Int64? = nil, threadID: UUID, sampledAt: Date,
                score: Double, source: VibeSource) {
        self.id = id
        self.threadID = threadID
        self.sampledAt = sampledAt
        self.score = max(-1, min(1, score))
        self.source = source
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
