import Foundation

/// The contact dossier — "remember every detail of the people who matter."
/// A short AI-written brief per person: who they are to the user + what's been
/// discussed lately, with the key details and open loops worth remembering
/// before the next conversation. Grounded ONLY in local data (cross-platform
/// transcript, the user's own memory note, the computed read/trajectory); the
/// deterministic fallback keeps the card honest keyless or on the free tier.
public struct DossierContext: Sendable {
    public var personName: String
    public var platforms: [String]
    public var goalText: String?
    public var memoryNote: String?
    public var styleChips: [String]
    public var trajectoryDriver: String?
    public var transcript: [ThreadTurn]
    // Public-profile enrichment (LinkedIn + web), all defaulted so contexts
    // without it compose exactly as before.
    public var headline: String?
    public var company: String?
    public var location: String?
    public var profileSummary: String?
    public var positions: [String]      // pre-flattened "title at company (period)"
    public var education: [String]
    public var webFacts: [String]       // text only — source URLs live in the UI

    public init(personName: String, platforms: [String] = [], goalText: String? = nil,
                memoryNote: String? = nil, styleChips: [String] = [],
                trajectoryDriver: String? = nil, transcript: [ThreadTurn] = [],
                headline: String? = nil, company: String? = nil, location: String? = nil,
                profileSummary: String? = nil, positions: [String] = [],
                education: [String] = [], webFacts: [String] = []) {
        self.personName = personName
        self.platforms = platforms
        self.goalText = goalText
        self.memoryNote = memoryNote
        self.styleChips = styleChips
        self.trajectoryDriver = trajectoryDriver
        self.transcript = transcript
        self.headline = headline
        self.company = company
        self.location = location
        self.profileSummary = profileSummary
        self.positions = positions
        self.education = education
        self.webFacts = webFacts
    }
}

public enum Dossier {
    /// Stable, cacheable core.
    public static let systemCore = """
        You write Osmo's contact dossiers — the brief a user skims before talking \
        to someone. From the provided history and notes, write TWO short sections:
        ABOUT: 1-2 sentences — who this person is to the user and where the \
        relationship stands, grounded in what's actually there.
        REMEMBER: 2-4 bullet lines — the key details discussed lately, promises \
        or open loops (who owes what), and anything time-sensitive. Each bullet \
        under 15 words, most recent first.
        Ground everything in the provided data; never invent facts. No preamble, \
        no advice, no quotation marks. Use exactly the ABOUT/REMEMBER headers. \
        A PUBLIC PROFILE or FROM THE WEB section may describe their professional \
        background from LinkedIn and public pages; use it to ground ABOUT (who \
        they are), and only surface it in REMEMBER when it connects to the \
        conversation.
        """

    public static func compose(_ ctx: DossierContext) -> ComposedPrompt {
        var s: [String] = []
        s.append("PERSON: \(ctx.personName)")
        if !ctx.platforms.isEmpty { s.append("YOU TALK ON: \(ctx.platforms.joined(separator: ", "))") }
        if let g = ctx.goalText, !g.isEmpty { s.append("USER'S GOAL WITH THEM: \(g)") }
        if let m = ctx.memoryNote, !m.isEmpty { s.append("USER'S OWN NOTES: \(m.prefix(400))") }
        // The enrichment layer: who they are publicly, before how they text.
        let hasProfile = (ctx.headline?.isEmpty == false) || (ctx.company?.isEmpty == false)
            || !ctx.positions.isEmpty || !ctx.education.isEmpty
            || (ctx.profileSummary?.isEmpty == false)
        if hasProfile {
            s.append("PUBLIC PROFILE (LinkedIn):")
            if let h = ctx.headline, !h.isEmpty { s.append("Headline: \(h)") }
            let role = [ctx.company, ctx.location].compactMap { $0 }.filter { !$0.isEmpty }
            if !role.isEmpty { s.append("At: \(role.joined(separator: " · "))") }
            if !ctx.positions.isEmpty { s.append("Positions: \(ctx.positions.prefix(3).joined(separator: "; "))") }
            if !ctx.education.isEmpty { s.append("Education: \(ctx.education.prefix(2).joined(separator: "; "))") }
            if let b = ctx.profileSummary, !b.isEmpty { s.append("Bio: \(b.prefix(300))") }
        }
        if !ctx.webFacts.isEmpty {
            s.append("FROM THE WEB (public mentions):")
            s.append(contentsOf: ctx.webFacts.prefix(6).map { "- \($0)" })
        }
        if !ctx.styleChips.isEmpty { s.append("HOW THEY COMMUNICATE: \(ctx.styleChips.joined(separator: ", "))") }
        if let t = ctx.trajectoryDriver { s.append("TREND: \(t)") }
        if !ctx.transcript.isEmpty {
            s.append("RECENT CONVERSATION (across platforms, most recent last):")
            s.append(ctx.transcript.suffix(40)
                .map { ($0.fromMe ? "You: " : "Them: ") + $0.text }
                .joined(separator: "\n"))
        }
        s.append("Write the ABOUT and REMEMBER sections.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }

    public struct Result: Equatable, Sendable {
        public var about: String
        public var remember: [String]
        public init(about: String, remember: [String]) { self.about = about; self.remember = remember }
    }

    /// Split ABOUT/REMEMBER; tolerant of bullets and loose spacing.
    public static func parseResult(_ raw: String) -> Result? {
        var about: [String] = []
        var remember: [String] = []
        var section = 0   // 0 none, 1 about, 2 remember
        for line in raw.components(separatedBy: .newlines) {
            var t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()
            if lower.hasPrefix("about:") { section = 1; t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if lower.hasPrefix("about") && t.count <= 7 { section = 1; continue }
            else if lower.hasPrefix("remember:") { section = 2; t = String(t.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            else if lower.hasPrefix("remember") && t.count <= 10 { section = 2; continue }
            guard !t.isEmpty else { continue }
            while let first = t.first, "-•*".contains(first) { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
            if section == 2 { remember.append(t) }
            else if section == 1 { about.append(t) }
            else { about.append(t); section = 1 }   // headerless start = about
        }
        let aboutText = about.joined(separator: " ")
        guard !aboutText.isEmpty || !remember.isEmpty else { return nil }
        return Result(about: aboutText, remember: Array(remember.prefix(5)))
    }

    /// Honest deterministic dossier when the model isn't available: built from
    /// what the user and the analyzers already know.
    public static func fallback(_ ctx: DossierContext) -> Result {
        var about: [String] = []
        // Public identity first — the strongest single "who they are" line.
        if let h = ctx.headline, !h.isEmpty {
            var lead = h.hasSuffix(".") ? h : h + "."
            if let l = ctx.location, !l.isEmpty { lead += " Based in \(l)." }
            about.append(lead)
        }
        if !ctx.platforms.isEmpty {
            about.append("You talk on \(ctx.platforms.joined(separator: " + ")).")
        }
        if !ctx.styleChips.isEmpty {
            about.append("Their style: \(ctx.styleChips.prefix(3).joined(separator: ", ").lowercased()).")
        }
        if let t = ctx.trajectoryDriver {
            about.append(t.prefix(1).capitalized + t.dropFirst() + ".")
        }
        var remember: [String] = []
        if let g = ctx.goalText, !g.isEmpty { remember.append("Your goal: \(g)") }
        if let m = ctx.memoryNote?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            remember.append(contentsOf: m.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(3).map { String($0.prefix(90)) })
        }
        if let lastTheirs = ctx.transcript.last(where: { !$0.fromMe }) {
            remember.append("Their last message: “\(String(lastTheirs.text.prefix(70)))”")
        }
        return Result(about: about.joined(separator: " "), remember: remember)
    }
}

extension SuggestionService {
    /// The AI dossier (single completion).
    public func dossier(_ ctx: DossierContext) async throws -> Dossier.Result {
        let prompt = Dossier.compose(ctx)
        let raw = try await generator.generate(
            systemCore: prompt.systemCore, userTurn: prompt.userTurn, count: 1)
        guard let result = Dossier.parseResult(raw) else { throw GenerationError.empty }
        return result
    }
}
