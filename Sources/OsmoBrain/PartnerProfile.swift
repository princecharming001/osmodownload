import Foundation

/// The read on the OTHER person — the pitch's core promise made computable:
/// "it learns how each person communicates — direct or warm, fast or slow,
/// formal or casual — and tells you the tonality to strike with them, and why."
///
/// Built deterministically from their real turns (no network, no guessing):
/// style from what they write, rhythm from when they write it. Pure + tested.
/// `chips` feed the person-page UI; `directives` feed the draft prompt; the
/// `tonality`/`why` pair is the human-readable strategy line.
public struct PartnerProfile: Equatable, Sendable {
    // MARK: Style
    /// Average words per message from them.
    public var avgWords: Int
    /// Share of their messages that are mostly lowercase.
    public var lowercaseShare: Double
    /// Share containing emoji.
    public var emojiShare: Double
    /// Share containing exclamation marks.
    public var exclaimShare: Double
    /// Share that ask a question (engagement/curiosity signal).
    public var questionShare: Double
    /// Formality: contractions + slang lower it; greetings/sign-offs raise it. 0…1.
    public var formality: Double

    // MARK: Rhythm
    /// Median time they take to reply to the user, when computable.
    public var medianReplySeconds: TimeInterval?
    /// The 6-hour block they message in most: "mornings" | "afternoons" |
    /// "evenings" | "late nights" (nil when too little data).
    public var activeBlock: String?
    /// How many of their turns informed this read.
    public var sampleCount: Int

    /// Not enough of their messages to say anything honest.
    public var isEmpty: Bool { sampleCount < 3 }

    // MARK: - Reading

    public static func read(_ turns: [ThreadTurn]) -> PartnerProfile {
        let theirs = turns.filter { !$0.fromMe }
        let texts = theirs.suffix(60).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let n = texts.count

        func share(_ predicate: (String) -> Bool) -> Double {
            n == 0 ? 0 : Double(texts.filter(predicate).count) / Double(n)
        }

        let lettered = texts.filter { $0.contains(where: \.isLetter) }
        let lowercase = lettered.isEmpty ? 0
            : Double(lettered.filter { $0 == $0.lowercased() }.count) / Double(lettered.count)

        // Formality: start neutral; casual markers pull down, formal markers up.
        var formality = 0.5
        let joined = texts.joined(separator: " ").lowercased()
        let casualHits = ["lol", "lmao", "haha", "omg", "gonna", "wanna", "bro", "dude",
                          "ur ", " u ", "idk", "tbh", "ngl", "fr ", "yea", "nah"]
            .filter { joined.contains($0) }.count
        let formalHits = ["regards", "best,", "sincerely", "thank you for", "please find",
                          "i would", "hello ", "good morning", "good afternoon", "appreciate your"]
            .filter { joined.contains($0) }.count
        formality += Double(formalHits) * 0.12 - Double(casualHits) * 0.08
        if lowercase > 0.6 { formality -= 0.15 }
        formality = min(1, max(0, formality))

        return PartnerProfile(
            avgWords: n == 0 ? 0 : texts.map { $0.split(separator: " ").count }.reduce(0, +) / n,
            lowercaseShare: lowercase,
            emojiShare: share(containsEmoji),
            exclaimShare: share { $0.contains("!") },
            questionShare: share { $0.contains("?") },
            formality: formality,
            medianReplySeconds: medianReplyGap(turns),
            activeBlock: readActiveBlock(theirs),
            sampleCount: n)
    }

    /// Median of the gaps between the user's message and their next reply — the
    /// honest "fast or slow" signal (their tempo toward YOU, not in general).
    static func medianReplyGap(_ turns: [ThreadTurn]) -> TimeInterval? {
        var gaps: [TimeInterval] = []
        for i in 1..<max(turns.count, 1) {
            guard turns[i-1].fromMe, !turns[i].fromMe,
                  let a = turns[i-1].sentAt, let b = turns[i].sentAt else { continue }
            let gap = b.timeIntervalSince(a)
            // Ignore instant-double-texts and multi-week gaps (not "reply tempo").
            if gap > 30, gap < 7 * 86_400 { gaps.append(gap) }
        }
        guard gaps.count >= 3 else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    /// The one bucket vocabulary — `activeBlock` labels and the "what block is it
    /// now" comparison in the prompt MUST share these, or they drift apart.
    static let blockNames = ["mornings", "afternoons", "evenings", "late nights"]

    /// Bucket index for an hour 0–23 (5–11 / 11–17 / 17–23; 23–5 wraps midnight).
    static func blockIndex(hour: Int) -> Int {
        switch hour {
        case 5..<11: return 0
        case 11..<17: return 1
        case 17..<23: return 2
        default: return 3
        }
    }

    /// Human name of the block an hour falls in ("mornings"…"late nights").
    public static func hourBlock(_ hour: Int) -> String { blockNames[blockIndex(hour: hour)] }

    static func readActiveBlock(_ theirs: [ThreadTurn]) -> String? {
        let hours = theirs.compactMap { $0.sentAt }
            .map { Calendar.current.component(.hour, from: $0) }
        guard hours.count >= 5 else { return nil }
        var buckets = [0, 0, 0, 0]
        for h in hours { buckets[blockIndex(hour: h)] += 1 }
        let top = buckets.enumerated().max(by: { $0.element < $1.element })!
        // Only claim a block when it actually dominates (> 40% of their messages).
        return Double(top.element) / Double(hours.count) > 0.4 ? blockNames[top.offset] : nil
    }

    // MARK: - Surfaces

    /// Short trait chips for the person page ("Reads people" made visible).
    public var chips: [String] {
        guard !isEmpty else { return [] }
        var out: [String] = []
        out.append(avgWords <= 7 ? "Brief texter" : avgWords <= 16 ? "Conversational" : "Long-form")
        out.append(formality < 0.35 ? "Casual" : formality > 0.65 ? "Formal" : "Relaxed")
        if emojiShare > 0.3 { out.append("Emoji-fluent") } else if emojiShare < 0.05 { out.append("No emoji") }
        if exclaimShare > 0.3 { out.append("High energy") }
        if questionShare > 0.35 { out.append("Asks questions") }
        if let m = medianReplySeconds {
            out.append(m < 15 * 60 ? "Replies fast" : m < 3 * 3600 ? "Replies within hours" : "Slow to reply")
        }
        if let block = activeBlock { out.append("Active \(block)") }
        return out
    }

    /// The one-line "tonality to strike" — the pitch's promise, per person.
    public var tonality: String? {
        guard !isEmpty else { return nil }
        let pace = avgWords <= 7 ? "brief" : "fuller"
        let register = formality < 0.35 ? "casual" : formality > 0.65 ? "polished" : "relaxed"
        let energy = exclaimShare > 0.3 || emojiShare > 0.3 ? "warm" : "even"
        return "Keep it \(pace), \(register), and \(energy) — that's how they talk."
    }

    /// Why the tonality holds (Linguistic Style Matching, plainly).
    public var why: String? {
        guard !isEmpty else { return nil }
        var facts: [String] = ["~\(max(avgWords, 1)) words per message"]
        if lowercaseShare > 0.6 { facts.append("mostly lowercase") }
        if emojiShare > 0.3 { facts.append("uses emoji freely") } else if emojiShare < 0.05 { facts.append("never emoji") }
        if let m = medianReplySeconds { facts.append("typically replies in \(Self.humanGap(m))") }
        return "Matching style signals rapport. They write \(facts.joined(separator: ", "))."
    }

    /// Prompt directives — how the model should adapt to THIS person durably
    /// (beyond the last message).
    public var directives: [String] {
        guard !isEmpty else { return [] }
        var out: [String] = []
        out.append("They typically write ~\(max(avgWords, 1)) words per message — stay near their length.")
        if lowercaseShare > 0.6 { out.append("They text in lowercase — mirroring it reads as rapport.") }
        out.append(emojiShare > 0.3 ? "They use emoji freely — one that fits is on-register."
                   : emojiShare < 0.05 ? "They never use emoji — don't introduce them." : "Emoji are rare for them — at most one, only if natural.")
        if formality > 0.65 { out.append("They write with polish — keep grammar clean, no slang.") }
        if formality < 0.35 { out.append("They're casual — polish would read as distance.") }
        if questionShare > 0.35 { out.append("They engage by asking questions — answering theirs fully lands well.") }
        return out
    }

    public static func humanGap(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3600: return "\(max(Int(seconds / 60), 1)) min"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    private static func containsEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }
}
