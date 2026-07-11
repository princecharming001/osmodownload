import Foundation

/// The per-conversation brief — one line that re-orients the user instantly:
/// what this thread is about right now, what they owe or promised, or the smart
/// angle for the reply. The LLM path reads recent history + the long-term read
/// on the person; the deterministic fallback guarantees a useful line even
/// keyless, offline, or on the free tier.
public struct InsightContext: Sendable {
    public var personName: String
    public var goalText: String?
    public var memoryNote: String?
    public var trajectoryDriver: String?
    public var verdictDetail: String?
    public var transcript: [ThreadTurn]

    public init(personName: String, goalText: String? = nil, memoryNote: String? = nil,
                trajectoryDriver: String? = nil, verdictDetail: String? = nil,
                transcript: [ThreadTurn] = []) {
        self.personName = personName
        self.goalText = goalText
        self.memoryNote = memoryNote
        self.trajectoryDriver = trajectoryDriver
        self.verdictDetail = verdictDetail
        self.transcript = transcript
    }
}

public enum Insight {
    /// Stable, cacheable core (same prompt-caching discipline as the drafts).
    /// One completion yields BOTH the topic label and the brief.
    public static let systemCore = """
        You write Osmo's conversation labels and briefs. Given one conversation \
        and what's known about the person, return EXACTLY TWO lines:
        TOPIC: a 1-3 word label for what this conversation is about (like \
        Engineering Hiring, Trip Planning, Catch-up, Rent Split)
        BRIEF: one line (max 20 words) that instantly re-orients the user — what \
        this thread is about right now, what they owe or promised, or the smart \
        angle for the reply. Concrete and specific to THIS conversation. No \
        advice clichés, no quotation marks, no emoji, no preamble.
        """

    public static func compose(_ ctx: InsightContext) -> ComposedPrompt {
        var s: [String] = []
        s.append("WHO: \(ctx.personName)")
        if let g = ctx.goalText, !g.isEmpty { s.append("YOUR GOAL WITH THEM: \(g)") }
        if let m = ctx.memoryNote, !m.isEmpty { s.append("WHAT YOU KNOW: \(m.prefix(300))") }
        if let t = ctx.trajectoryDriver { s.append("TREND: \(t)") }
        if let v = ctx.verdictDetail { s.append("TIMING: \(v)") }
        if !ctx.transcript.isEmpty {
            s.append("CONVERSATION (most recent last):")
            s.append(ctx.transcript.suffix(10)
                .map { ($0.fromMe ? "You: " : "\(($0.senderName ?? "Them")): ") + $0.text }
                .joined(separator: "\n"))
        }
        s.append("Write the TOPIC and BRIEF lines.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }

    public struct Result: Equatable, Sendable {
        public var topic: String?
        public var brief: String
        public init(topic: String?, brief: String) { self.topic = topic; self.brief = brief }
    }

    /// Parse the TOPIC/BRIEF pair; tolerates a bare single line (treated as the
    /// brief) so older cached outputs and loose models still work.
    public static func parseResult(_ raw: String) -> Result? {
        var topic: String?
        var brief: String?
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()
            if lower.hasPrefix("topic:") {
                topic = clean(String(t.dropFirst(6)))
            } else if lower.hasPrefix("brief:") {
                brief = clean(String(t.dropFirst(6)))
            } else if brief == nil, topic != nil || !lower.contains(":") {
                brief = clean(t)   // bare line = the brief
            }
        }
        // Clamp the label to something chip-sized.
        if let t = topic, t.split(separator: " ").count > 3 || t.count > 28 { topic = nil }
        guard let b = brief, !b.isEmpty else { return nil }
        return Result(topic: topic?.isEmpty == true ? nil : topic, brief: b)
    }

    /// Strip bullet/quote wrapping (re-trimming between passes — "- “x”") + clamp.
    static func clean(_ s: String) -> String {
        var text = s
        while true {
            text = text.trimmingCharacters(in: .whitespaces)
            if let first = text.first, "-•\"'“”".contains(first) { text.removeFirst() } else { break }
        }
        while let last = text.last, "\"'“”".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }

    /// First real line of model output, cleaned and clamped.
    public static func parse(_ raw: String) -> String? {
        let line = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        let text = clean(line)
        return text.isEmpty ? nil : text
    }

    /// Deterministic brief when the model isn't available (or worth it): the
    /// goal, the saved memory, or the trend — whichever re-orients best.
    public static func fallback(_ ctx: InsightContext) -> String? {
        if let last = ctx.transcript.last, !last.fromMe, last.text.contains("?") {
            return "They asked a question — answering it first is the whole reply."
        }
        if let g = ctx.goalText, !g.isEmpty {
            return "Your goal here: \(g) — this reply can move it."
        }
        if let m = ctx.memoryNote?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            let firstLine = m.components(separatedBy: .newlines).first ?? m
            return "You noted: \(String(firstLine.prefix(90)))"
        }
        if let t = ctx.trajectoryDriver { return t.prefix(1).capitalized + t.dropFirst() + "." }
        return ctx.verdictDetail
    }
}

extension SuggestionService {
    /// Topic label + one-line brief via the live model (single completion).
    public func insight(_ ctx: InsightContext) async throws -> Insight.Result {
        let prompt = Insight.compose(ctx)
        let raw = try await generator.generate(
            systemCore: prompt.systemCore, userTurn: prompt.userTurn, count: 1)
        guard let result = Insight.parseResult(raw) else { throw GenerationError.empty }
        return result
    }
}
