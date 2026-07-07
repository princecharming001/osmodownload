import Foundation

/// "Read before you send" — the overthink-stopper. Analyzes the USER'S draft
/// against how this person actually communicates and where the thread stands,
/// and answers the only question that matters at 11pm with a half-typed message:
/// is this fine to send?
///
/// Deterministic, instant, free — no model call, no waiting, no meter. The
/// verdict language is reassurance-first by design: Osmo exists to stop the
/// spiral, not to grade homework. No flags → "send it", full stop.
public struct ToneCheck: Equatable, Sendable {
    public struct Flag: Equatable, Sendable {
        public var title: String
        public var detail: String
        public init(title: String, detail: String) { self.title = title; self.detail = detail }
    }

    public var flags: [Flag]
    /// The one-line answer ("This lands fine — send it.").
    public var verdict: String
    /// Reassurance bias: true unless multiple real flags stack up.
    public var sendable: Bool

    public static func check(draft: String, partner: PartnerProfile,
                             read: ThreadRead) -> ToneCheck {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ToneCheck(flags: [], verdict: "Nothing to check yet.", sendable: false)
        }
        let lower = text.lowercased()
        let words = text.split { $0 == " " || $0 == "\n" }.count
        var flags: [Flag] = []

        // Length vs how you two actually text.
        if !partner.isEmpty, partner.avgWords > 0, words > max(30, partner.avgWords * 3) {
            flags.append(Flag(title: "Longer than you two usually text",
                              detail: "They write ~\(partner.avgWords) words a message. A wall of text can read as heavy — trim to the part that matters."))
        }

        // Question pile-up.
        let questions = text.filter { $0 == "?" }.count
        if questions >= 3 {
            flags.append(Flag(title: "\(questions) questions at once",
                              detail: "Stacked questions read like an interview. Pick the one you actually want answered."))
        }

        // Chasing energy — worst when you're already carrying the thread.
        // Question forms only — "see you there" must never read as chasing.
        let chaseMarkers = ["??", "hello?", "you there?", "u there?", "why aren't you",
                            "did you see my", "just checking in again", "just following up again"]
        let askReply = ["let me know", "lmk", "please respond", "please reply", "get back to me"]
        let chasing = chaseMarkers.contains { lower.contains($0) }
            || (read.userCarrying && askReply.contains { lower.contains($0) })
        if chasing {
            flags.append(Flag(title: "Reads like chasing",
                              detail: read.userCarrying
                                ? "You already have the last word in this thread. Pressure for a reply pushes people away — drop the ask and let the message stand."
                                : "Demanding a reply reads anxious. Say the thing; the reply takes care of itself."))
        }

        // Apology overload.
        let sorries = lower.components(separatedBy: "sorry").count - 1
        if sorries >= 2 {
            flags.append(Flag(title: "\(sorries) sorries",
                              detail: "One clean sorry lands stronger than several anxious ones."))
        }

        // Register mismatch with THIS person.
        if !partner.isEmpty {
            let formalMarkers = ["dear ", "regards", "sincerely", "i hope this finds you"]
            let hasFormal = formalMarkers.contains { lower.contains($0) }
            if partner.formality < 0.35, hasFormal {
                flags.append(Flag(title: "More formal than how they talk",
                                  detail: "They're casual with you — polish here reads as distance, not respect."))
            }
            let emoji = text.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count
            if partner.emojiShare < 0.05, emoji >= 2 {
                flags.append(Flag(title: "Emoji they'd never send",
                                  detail: "They don't use emoji with you — a couple of yours can feel off-register."))
            }
        }

        // Hedging pile-up.
        let hedges = ["just ", "maybe ", "kind of", "sort of", "i think ", "if that's okay",
                      "if that makes sense", "no worries if not", "totally fine if"]
        let hedgeCount = hedges.reduce(0) { $0 + (lower.components(separatedBy: $1).count - 1) }
        if hedgeCount >= 3 {
            flags.append(Flag(title: "Hedging stacks up",
                              detail: "\(hedgeCount) softeners in one message. Say it straight — it reads more confident and kinder."))
        }

        // Intensity.
        let exclaims = text.filter { $0 == "!" }.count
        if exclaims >= 3 {
            flags.append(Flag(title: "A lot of exclamation",
                              detail: "Past two, energy starts reading as nerves. Keep the one that's real."))
        }

        let verdict: String
        switch flags.count {
        case 0: verdict = "This lands fine — send it."
        case 1: verdict = "Nearly there — one small thing."
        default: verdict = "Worth a quick second pass."
        }
        return ToneCheck(flags: flags, verdict: verdict, sendable: flags.count <= 1)
    }
}
