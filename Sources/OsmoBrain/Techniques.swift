import Foundation

/// A research-grounded communication technique. Data, not prose: the engine picks
/// applicable techniques by (goal × move × register × thread state), injects each
/// one's `directive` into the prompt, and surfaces its `why` as the take's
/// "why this works." Sources are named so the psychology is citable, never vibes.
public struct Technique: Equatable, Sendable, Identifiable {
    public enum Family: String, Sendable { case negotiation, relationship, influence, clarity, style }
    public var id: String
    public var name: String
    public var family: Family
    /// The one-line rationale shown to the user.
    public var why: String
    /// What the model should actually do (injected into the prompt).
    public var directive: String

    public init(id: String, name: String, family: Family, why: String, directive: String) {
        self.id = id; self.name = name; self.family = family; self.why = why; self.directive = directive
    }
}

/// The catalog. Kept flat + addressable by id so `Strategy` composes from it and
/// tests can assert specific picks.
public enum TechniqueCatalog {
    public static let all: [Technique] = [
        // — Negotiation (Voss / tactical empathy) —
        Technique(id: "labeling", name: "Labeling", family: .negotiation,
            why: "Naming the other person's emotion out loud makes them feel understood and lowers their guard (Voss, tactical empathy).",
            directive: "Open by naming what they're likely feeling with a soft label — \"it sounds like…\", \"it seems like…\" — before anything else."),
        Technique(id: "calibrated-question", name: "Calibrated question", family: .negotiation,
            why: "A \"how\"/\"what\" question hands them the problem to solve and moves things forward without pressure (Voss).",
            directive: "Advance with one open \"how\" or \"what\" question that invites them to shape the next step; never a yes/no push."),
        Technique(id: "mirroring", name: "Mirroring", family: .negotiation,
            why: "Echoing their last few words invites them to elaborate and keeps you in sync (Voss).",
            directive: "Where natural, lightly echo a key phrase of theirs to show you're tracking and to draw them out."),
        Technique(id: "accusation-audit", name: "Accusation audit", family: .negotiation,
            why: "Naming the worst thing they might think first defuses it before it derails the ask (Voss).",
            directive: "Pre-empt the likely objection by naming it plainly and briefly, then continue."),
        Technique(id: "anchor-future", name: "Future anchor", family: .negotiation,
            why: "Painting the shared outcome makes the yes feel like moving toward something, not conceding.",
            directive: "Briefly anchor the ask to the outcome you both want, so it reads as forward motion."),

        // — Relationship (Gottman / attachment / support) —
        Technique(id: "own-it-apology", name: "Clean apology", family: .relationship,
            why: "An apology that owns the specific thing without \"but\"/\"if\" actually repairs; a qualified one deepens the rupture (Gottman repair).",
            directive: "Own the specific thing in the first line. Never follow \"sorry\" with \"but\" or \"if\". Name its impact on them, offer one concrete repair, apologize once."),
        Technique(id: "soft-startup", name: "Soft start-up", family: .relationship,
            why: "Raising something hard gently (\"I\" not \"you\", one issue) keeps them from going defensive (Gottman).",
            directive: "Start soft: speak from \"I\", raise exactly one thing, no criticism of their character."),
        Technique(id: "repair-attempt", name: "Repair attempt", family: .relationship,
            why: "A small de-escalating gesture mid-conflict stops the spiral (Gottman).",
            directive: "Include one small repair gesture — acknowledge their side, or a bit of warmth — to lower the temperature."),
        Technique(id: "turn-toward-bid", name: "Turn toward the bid", family: .relationship,
            why: "Responding to the feeling under their message, not just the content, builds closeness (Gottman bids).",
            directive: "Answer the emotional bid under their words, not only the literal content."),
        Technique(id: "validate-first", name: "Validate first", family: .relationship,
            why: "When someone's struggling, feeling heard beats being fixed; advice unasked-for pushes them away.",
            directive: "Validate the feeling first and specifically. No advice unless they asked. Never \"at least…\"."),
        Technique(id: "specific-presence", name: "Specific presence", family: .relationship,
            why: "A concrete offer (\"I can call tonight\") lands where a vague \"let me know if you need anything\" doesn't.",
            directive: "Offer specific presence over a vague open door."),

        // — Influence (Cialdini) —
        Technique(id: "reciprocity", name: "Reciprocity", family: .influence,
            why: "Leading with genuine value makes people want to give back (Cialdini).",
            directive: "Lead with something useful to them before the ask, if there's something genuine to offer."),
        Technique(id: "commitment", name: "Consistency", family: .influence,
            why: "Anchoring to something they already said/value makes the next step feel consistent (Cialdini).",
            directive: "Tie the ask to something they've already agreed to or care about."),
        Technique(id: "easy-yes", name: "Easy yes", family: .influence,
            why: "A small, low-friction first step is far more likely to get a yes than a big one.",
            directive: "Make the ask the smallest possible next step, with a concrete option they can accept in one tap."),
        Technique(id: "face-saving-no", name: "Face-saving decline", family: .influence,
            why: "Warmth first + one clean no + an easy out lets them keep face and keeps the relationship (politeness theory).",
            directive: "Warmth first, then one clear no. At most one short reason. Offer a real alternative only if you mean it."),

        // — Clarity —
        Technique(id: "answer-first", name: "Answer their question first", family: .clarity,
            why: "Answering what they actually asked, up front, signals respect and prevents crossed wires.",
            directive: "Answer their open question in the first sentence, before anything else."),
        Technique(id: "one-clear-ask", name: "One clear ask", family: .clarity,
            why: "Burying the ask makes it easy to ignore; one clear ask in the first line gets a decision.",
            directive: "Put the ask in the first sentence. One ask. Give an easy out exactly once."),
        Technique(id: "news-first", name: "Lead with the news", family: .clarity,
            why: "A long warm-up before hard news reads as dread; direct-about-fact, soft-about-person lands better.",
            directive: "Deliver the news within the first two sentences. Be direct about the fact, warm about the person."),

        // — Style (LSM) —
        Technique(id: "lsm-match", name: "Style matching", family: .style,
            why: "Matching their length, casing, and energy makes a message feel like it fits the conversation (Linguistic Style Matching).",
            directive: "Match their message's length, capitalization, punctuation, and energy.")
    ]

    public static func by(_ id: String) -> Technique {
        all.first { $0.id == id } ?? all[0]
    }
}
