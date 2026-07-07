import Foundation

/// Kinso-style auto-labels, computed locally: what is this conversation ABOUT?
/// Deterministic keyword scoring over recent messages — instant, free, and the
/// honest fallback under the LLM topic (which overrides when available). A
/// topic is only claimed on ≥2 hits; most small talk stays unlabeled.
public enum TopicClassifier {
    /// Ordered by precedence for ties — the more specific business topics first.
    static let topics: [(name: String, keywords: [String])] = [
        ("Hiring", ["hiring", "recruit", "the role", "position", "candidate", "resume",
                    "interview", "job offer", "referral"]),
        ("Fundraising", ["investor", "fundrais", "term sheet", "cap table", "the round",
                         "valuation", "pitch deck", "angel", "vc "]),
        ("Sales", ["pricing", "proposal", "contract", "the demo", "quote", "onboarding call",
                   "renewal", "your team"]),
        ("Money", ["venmo", "zelle", "paypal", "you owe", "i owe", "pay you back",
                   "split it", "invoice", "rent "]),
        ("Travel", ["flight", "the trip", "airbnb", "hotel", "airport", "itinerary",
                    "landing", "visa "]),
        ("School", ["class", "exam", "homework", "professor", "midterm", "final",
                    "lecture", "assignment", "semester"]),
        ("Work", ["meeting", "deadline", "the project", "standup", "launch", "ship it",
                  "code review", "the doc", "slides"]),
        ("Plans", ["dinner", "tonight", "tomorrow", "this weekend", "hang", "party",
                   "movie", "lunch", "coffee", "pull up", "come over", "free friday",
                   "free saturday"]),
        ("Catch-up", ["how are you", "how've you been", "long time", "miss you",
                      "what's new", "been a while", "catch up"]),
    ]

    /// Label for a conversation from its recent messages (both sides), or nil
    /// when nothing dominates — no label beats a wrong label.
    public static func classify(_ texts: [String]) -> String? {
        guard !texts.isEmpty else { return nil }
        let joined = texts.joined(separator: " ").lowercased()
        var best: (name: String, hits: Int)? = nil
        for topic in topics {
            let hits = topic.keywords.reduce(0) { $0 + occurrences(of: $1, in: joined) }
            if hits >= 2, hits > (best?.hits ?? 0) { best = (topic.name, hits) }
        }
        return best?.name
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
