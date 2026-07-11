import Foundation

/// "Ask Osmo" — natural-language questions over the user's own relationship
/// data ("who do I know in tech in SF?", "what did Sarah say about the lease?").
/// The app retrieves locally (FTS snippets + the people directory); the model
/// only ever sees what retrieval hands it, and is instructed to refuse rather
/// than invent. Privacy shape: retrieval local, synthesis through the same
/// proxy the drafts already use.
public struct AskContext: Sendable {
    public var question: String
    /// "[platform · person · date] text" lines from local full-text search.
    public var snippets: [String]
    /// Compact one-line-per-person directory entries (name · platforms · state
    /// · goal · noted). Powers who-do-I-know questions FTS can't answer.
    public var people: [String]
    /// A short note about the USER — their goals / self-described style /
    /// struggles from onboarding — so answers are framed for who they are.
    /// Empty string ⇒ omitted.
    public var about: String
    /// Prior exchanges this session ("Q: …" / "A: …" lines, oldest first) —
    /// follow-ups like "what about her?" need them.
    public var history: [String]

    public init(question: String, snippets: [String] = [], people: [String] = [],
                about: String = "", history: [String] = []) {
        self.question = question
        self.snippets = snippets
        self.people = people
        self.about = about
        self.history = history
    }
}

/// One tappable action offered under an answer — parsed from the model's
/// trailing ACTIONS line, resolved against real people/threads by the app.
public struct AskAction: Equatable, Sendable, Codable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case draft      // open the conversation with the draft affordance
        case open       // just open the conversation
        case remind     // arm a follow-up reminder
        case snooze     // quiet the thread for a while
    }
    public var kind: Kind
    public var person: String
    /// remind/snooze horizon in days (model-suggested; app clamps 1...30).
    public var days: Int?
    public var id: String { "\(kind.rawValue)-\(person)" }

    public init(kind: Kind, person: String, days: Int? = nil) {
        self.kind = kind
        self.person = person
        self.days = days
    }
}

public enum Ask {
    /// Stable, cacheable core.
    public static let systemCore = """
        You are Osmo — the user's sharp, warm relationship sidekick, answering \
        questions about THEIR own conversations and contacts. Ground every claim \
        in the CONTACTS and SNIPPETS provided; if it isn't there, say so plainly. \
        Never invent people, quotes, or facts.

        Voice: talk like a perceptive friend, not a search index. Lead with the \
        answer in one or two plain sentences. Add the human read when it's real \
        (tone, momentum, what they seem to want) — never clinical inventories, \
        never citation dumps like "several snippets are addressed to you". \
        Quote at most one short line when it genuinely helps.

        The user is IN these conversations: "You:" lines are theirs, and when \
        their own name appears in messages, other people are talking to or \
        about THEM — never narrate the user in third person.

        When a next move is obvious, end with ONE light, practical suggestion \
        (e.g. "want me to draft a quick reply?") — an offer, not homework. \
        Skip it when nothing is called for.

        ACTIONS: when (and only when) a concrete next step exists for a person \
        who appears in CONTACTS, append ONE final line, exactly: \
        ACTIONS: [{"kind":"draft|open|remind|snooze","person":"<their name as \
        listed>","days":<int, only for remind/snooze>}] — at most 3 entries, \
        valid JSON, nothing after it. The app renders these as buttons; the \
        line itself is never shown, so don't reference it in prose.
        """

    public static func compose(_ ctx: AskContext) -> ComposedPrompt {
        var s: [String] = []
        if !ctx.about.isEmpty {
            s.append("ABOUT THE USER (for framing, not a source of facts): \(ctx.about)")
        }
        if !ctx.history.isEmpty {
            s.append("RECENT CONVERSATION (for continuity; the QUESTION below is the live one):")
            s.append(contentsOf: ctx.history.suffix(8))
        }
        if !ctx.people.isEmpty {
            s.append("CONTACTS (name · role @ company · platforms · state · goal · noted):")
            s.append(contentsOf: ctx.people.prefix(50).map { "- \($0)" })
        }
        if !ctx.snippets.isEmpty {
            s.append("\nSNIPPETS from their real messages:")
            s.append(contentsOf: ctx.snippets.prefix(40).map { "- \($0)" })
        }
        s.append("\nQUESTION: \(ctx.question)")
        s.append("Answer from the context above only.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }
}

extension Ask {
    /// Split a raw completion into prose + the trailing ACTIONS line. Tolerant:
    /// a malformed block (or entries with unknown kinds) degrades to plain
    /// prose — a broken action must never eat the answer.
    public static func split(answer raw: String) -> (prose: String, actions: [AskAction]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markerRange = trimmed.range(of: "ACTIONS:", options: [.backwards]) else {
            return (trimmed, [])
        }
        let prose = String(trimmed[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = String(trimmed[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.hasPrefix("["), let data = payload.data(using: .utf8) else {
            return (trimmed, [])   // marker without a JSON array — leave the text intact
        }
        struct Loose: Decodable { var kind: String?; var person: String?; var days: Int? }
        guard let loose = try? JSONDecoder().decode([Loose].self, from: data) else {
            return (trimmed, [])
        }
        var seen = Set<String>()
        let actions = loose.compactMap { e -> AskAction? in
            guard let k = e.kind.flatMap(AskAction.Kind.init(rawValue:)),
                  let p = e.person?.trimmingCharacters(in: .whitespaces), !p.isEmpty
            else { return nil }
            let clamped = e.days.map { min(max($0, 1), 30) }
            let action = AskAction(kind: k, person: p, days: clamped)
            return seen.insert(action.id).inserted ? action : nil
        }
        return (prose.isEmpty ? trimmed : prose, Array(actions.prefix(3)))
    }
}

extension SuggestionService {
    /// One grounded answer (single completion).
    public func ask(_ ctx: AskContext) async throws -> String {
        let prompt = Ask.compose(ctx)
        let raw = try await generator.generate(
            systemCore: prompt.systemCore, userTurn: prompt.userTurn, count: 1)
        let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw GenerationError.empty }
        return answer
    }
}
