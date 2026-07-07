import Foundation
import OsmoCore

/// Pure inbox-filter logic, hoisted out of the view so it's unit-tested and the
/// view can't accidentally break it. `present` gives the chips to show (only
/// platforms that actually have threads); `apply` filters the list.
public enum InboxFilter {
    /// Platforms that have at least one thread, in canonical order.
    public static func present(in threads: [OsmoThread]) -> [Platform] {
        let have = Set(threads.map(\.platform))
        return Platform.allCases.filter { have.contains($0) }
    }

    /// Threads matching the selected platform (nil = all).
    public static func apply(_ filter: Platform?, to threads: [OsmoThread]) -> [OsmoThread] {
        guard let filter else { return threads }
        return threads.filter { $0.platform == filter }
    }

    /// "Unanswered" = the ball is in the user's court (they wrote last and the
    /// user hasn't replied). The app supplies that per-thread fact.
    public static func unanswered(_ threads: [OsmoThread],
                                  awaitingReply: (UUID) -> Bool) -> [OsmoThread] {
        threads.filter { awaitingReply($0.id) }
    }

    /// Threads carrying a specific topic label (an unlabeled thread ≠ a match).
    public static func topic(_ threads: [OsmoThread], label: String,
                             topicOf: (UUID) -> String?) -> [OsmoThread] {
        threads.filter { topicOf($0.id) == label }
    }

    /// The distinct topic labels present, sorted — feeds the filter menu.
    public static func presentTopics(in threads: [OsmoThread],
                                     topicOf: (UUID) -> String?) -> [String] {
        Array(Set(threads.compactMap { topicOf($0.id) })).sorted()
    }

    /// Threads at exactly the selected urgency level (an unclassified thread ≠
    /// a match — the filter only surfaces threads the intel layers actually flagged).
    public static func urgency(_ threads: [OsmoThread], level: IntelUrgency,
                               urgencyOf: (UUID) -> IntelUrgency?) -> [OsmoThread] {
        threads.filter { urgencyOf($0.id) == level }
    }

    /// Threads whose owed action matches the selected kind.
    public static func action(_ threads: [OsmoThread], kind: IntelAction,
                              actionOf: (UUID) -> IntelAction?) -> [OsmoThread] {
        threads.filter { actionOf($0.id) == kind }
    }

    /// Urgency levels actually present (excluding `.none`, which isn't a
    /// meaningful filter option) — feeds the filter menu.
    public static func presentUrgencies(in threads: [OsmoThread],
                                        urgencyOf: (UUID) -> IntelUrgency?) -> [IntelUrgency] {
        let have = Set(threads.map(\.id).compactMap(urgencyOf)).subtracting([.none])
        return IntelUrgency.allCases.filter { have.contains($0) }
    }

    /// Action kinds actually present — feeds the filter menu.
    public static func presentActions(in threads: [OsmoThread],
                                      actionOf: (UUID) -> IntelAction?) -> [IntelAction] {
        let have = Set(threads.map(\.id).compactMap(actionOf))
        return IntelAction.allCases.filter { have.contains($0) }
    }
}

/// "Conversations that connect themselves" — related threads for the open one:
/// every other thread with the SAME person (cross-platform, via the identity
/// graph), then threads sharing its topic label. Pure; the app supplies lookups.
public enum RelatedThreads {
    public static func find(for threadID: UUID,
                            in threads: [OsmoThread],
                            personOf: (UUID) -> UUID?,
                            topicOf: (UUID) -> String?,
                            limit: Int = 5) -> [OsmoThread] {
        let person = personOf(threadID)
        let topic = topicOf(threadID)
        var samePerson: [OsmoThread] = []
        var sameTopic: [OsmoThread] = []
        for t in threads where t.id != threadID {
            if let person, personOf(t.id) == person { samePerson.append(t) }
            else if let topic, topicOf(t.id) == topic { sameTopic.append(t) }
        }
        // Same-person links are certain (identity graph); topic links fill in.
        return Array((samePerson + sameTopic).prefix(limit))
    }
}
