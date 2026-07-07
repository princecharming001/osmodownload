import Foundation

/// The context layer captured during onboarding — WHY the user is here, how they
/// see themselves, and who matters — persisted and fed into every draft + Ask
/// prompt so Osmo caters to them from the very first message. This is what the
/// user *thinks/wants* their voice to be; the AI still learns their *actual*
/// style from synced conversations later (the two complement each other). Pure +
/// Codable + testable; no SwiftUI, no storage — the app owns persistence.
public struct OnboardingProfile: Codable, Equatable, Sendable {

    public enum Goal: String, Codable, CaseIterable, Sendable, Identifiable {
        case stopDroppingReplies, keepInTouch, writeBetter, rememberDetails, manageInbox
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .stopDroppingReplies: return "Stop dropping replies"
            case .keepInTouch:         return "Keep in touch with people who matter"
            case .writeBetter:         return "Write better, faster messages"
            case .rememberDetails:     return "Remember details about people"
            case .manageInbox:         return "Stay on top of a busy inbox"
            }
        }
        /// Verb clause for the prompt preamble ("They're using Osmo to …").
        var clause: String {
            switch self {
            case .stopDroppingReplies: return "not drop replies"
            case .keepInTouch:         return "keep in touch with people who matter"
            case .writeBetter:         return "write better, faster messages"
            case .rememberDetails:     return "remember details about people"
            case .manageInbox:         return "stay on top of a busy inbox"
            }
        }
    }

    public enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        case warm, direct, playful, professional, thoughtful, concise
        public var id: String { rawValue }
        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    public enum Struggle: String, Codable, CaseIterable, Sendable, Identifiable {
        case overthinking, forgettingFollowUp, tone, keepingTrack, startingConversations
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .overthinking:          return "Overthinking replies"
            case .forgettingFollowUp:    return "Forgetting to follow up"
            case .tone:                  return "Getting the tone right"
            case .keepingTrack:          return "Keeping track of everyone"
            case .startingConversations: return "Starting conversations"
            }
        }
        var clause: String {
            switch self {
            case .overthinking:          return "overthinking replies"
            case .forgettingFollowUp:    return "forgetting to follow up"
            case .tone:                  return "getting the tone right"
            case .keepingTrack:          return "keeping track of everyone"
            case .startingConversations: return "starting conversations"
            }
        }
    }

    public var goals: Set<Goal> = []
    public var styles: Set<Style> = []
    public var struggles: Set<Struggle> = []
    /// Display names of the people the user flagged as most important (picked from
    /// real synced conversations, not free text).
    public var keyPeople: [String] = []

    public init(goals: Set<Goal> = [], styles: Set<Style> = [],
                struggles: Set<Struggle> = [], keyPeople: [String] = []) {
        self.goals = goals; self.styles = styles
        self.struggles = struggles; self.keyPeople = keyPeople
    }

    public var isEmpty: Bool {
        goals.isEmpty && styles.isEmpty && struggles.isEmpty && keyPeople.isEmpty
    }

    /// A compact, natural-language preamble injected into draft + Ask prompts so
    /// the model tailors to this person. Empty string when nothing was captured
    /// (so callers can skip it cleanly). Stable ordering for cache-friendliness.
    public var promptPreamble: String {
        var parts: [String] = []
        if !goals.isEmpty {
            let g = Goal.allCases.filter(goals.contains).map(\.clause)
            parts.append("They're using Osmo to " + list(g) + ".")
        }
        if !styles.isEmpty {
            let s = Style.allCases.filter(styles.contains).map { $0.label.lowercased() }
            parts.append("They want to come across as " + list(s) + ".")
        }
        if !struggles.isEmpty {
            let st = Struggle.allCases.filter(struggles.contains).map(\.clause)
            parts.append("They tend to struggle with " + list(st) + ".")
        }
        if !keyPeople.isEmpty {
            parts.append("People who matter most to them: " + keyPeople.prefix(6).joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
