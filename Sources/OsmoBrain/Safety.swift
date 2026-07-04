import Foundation

/// The guardrail. Osmo coaches persuasion and clarity, never deception or the
/// exploitation of a vulnerable target — this is both an ethics line and the
/// EU AI Act Art.5 / FTC-unfairness defense. The engine frames psychology as
/// empathy ("communicate the way they'll hear it"), never as manipulation.
public enum Safety {
    public enum Verdict: Equatable, Sendable {
        case allow
        /// Blocked with a user-facing reason.
        case refuse(String)
    }

    /// Check the drafting request. Refuses coercion, deception toward a person,
    /// and anything targeting a self-declared vulnerable state. Keyword-floor +
    /// co-occurrence — the model prompt carries the fuller policy.
    public static func check(goal: String?, intent: String?, transcript: String?) -> Verdict {
        let hay = [goal, intent, transcript].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !hay.isEmpty else { return .allow }

        for phrase in hardRefusals where hay.contains(phrase) {
            return .refuse(reason)
        }
        // Coercion/deception verbs co-occurring with a person-target.
        let manipulative = ["manipulate", "gaslight", "coerce", "pressure them into",
                            "guilt trip", "guilt-trip", "trick them", "deceive", "lie to them",
                            "exploit their", "prey on", "wear them down"]
        if manipulative.contains(where: hay.contains) { return .refuse(reason) }
        return .allow
    }

    private static let reason =
        "Osmo helps you communicate clearly and with empathy — not to manipulate or deceive someone. Try reframing the goal around what you genuinely want them to understand."

    private static let hardRefusals = [
        "get them to send money", "get nudes", "get them to send pics",
        "someone who is drunk", "they are drunk", "underage", "a minor",
        "revenge", "make them jealous to", "isolate them from"
    ]
}
