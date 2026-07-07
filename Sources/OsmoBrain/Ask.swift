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

    public init(question: String, snippets: [String] = [], people: [String] = [], about: String = "") {
        self.question = question
        self.snippets = snippets
        self.people = people
        self.about = about
    }
}

public enum Ask {
    /// Stable, cacheable core.
    public static let systemCore = """
        You are Osmo's local assistant, answering the user's questions about their \
        own conversations and contacts. Answer ONLY from the CONTACTS and SNIPPETS \
        provided — if the answer isn't there, say plainly that you don't see it in \
        their messages; never invent people, quotes, or facts. Be concise and \
        direct, in second person, at most a short paragraph (or a short list when \
        listing people). No preamble.
        """

    public static func compose(_ ctx: AskContext) -> ComposedPrompt {
        var s: [String] = []
        if !ctx.about.isEmpty {
            s.append("ABOUT THE USER (for framing, not a source of facts): \(ctx.about)")
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
