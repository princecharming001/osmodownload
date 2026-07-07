import Foundation

// Shared vocabulary for the inbox's deeper classification layers (Action/Time/
// Emotion/Weight). Lives in OsmoCore because both OsmoBrain (the LLM pass) and
// OsmoShell (the deterministic pass) depend on it, and OsmoBrain/OsmoShell
// don't depend on each other.

/// How pressing a thread is right now.
public enum IntelUrgency: String, Codable, Sendable, CaseIterable {
    case none, soon, today, overdue
}

/// What kind of response this thread is actually waiting on.
public enum IntelAction: String, Codable, Sendable, CaseIterable {
    case reply, decide, schedule, pay, task, fyi
}

/// How much thought a good reply will take.
public enum IntelEffort: String, Codable, Sendable {
    case quick, thoughtful
}

/// Their tone on the most recent message.
public enum IntelTemperature: String, Codable, Sendable {
    case warm, neutral, cool
}
