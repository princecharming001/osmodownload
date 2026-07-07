import Foundation
import OsmoCore

/// The richer successor to `Insight`: one completion that reads a conversation
/// and returns not just a topic/brief but the deeper inbox layers the user
/// asked for — urgency, the action actually owed, open questions, commitments
/// the user made, their tone, and an automated-sender read. Same house pattern
/// (compose/parseResult/fallback/SuggestionService extension) and — critically
/// — still exactly ONE completion per thread per new message: this replaces
/// Insight's call, it doesn't add a second one. `Insight` itself stays in the
/// tree as the deterministic-brief fallback and legacy cache format.
public struct ThreadIntel: Equatable, Sendable {
    public var topic: String?
    public var brief: String?
    public var urgency: IntelUrgency?
    public var urgencyReason: String?
    public var action: IntelAction?
    public var openQuestion: Bool?
    /// Things the USER promised them — at most 2, shortest useful phrasing.
    public var commitments: [String]
    public var tone: String?
    public var temperature: IntelTemperature?
    public var effort: IntelEffort?
    public var automated: Bool?

    public init(topic: String? = nil, brief: String? = nil, urgency: IntelUrgency? = nil,
                urgencyReason: String? = nil, action: IntelAction? = nil, openQuestion: Bool? = nil,
                commitments: [String] = [], tone: String? = nil, temperature: IntelTemperature? = nil,
                effort: IntelEffort? = nil, automated: Bool? = nil) {
        self.topic = topic; self.brief = brief
        self.urgency = urgency; self.urgencyReason = urgencyReason
        self.action = action; self.openQuestion = openQuestion
        self.commitments = commitments; self.tone = tone
        self.temperature = temperature; self.effort = effort; self.automated = automated
    }
}

public enum ThreadIntelBrain {
    /// Stable, cacheable core — extends Insight's TOPIC/BRIEF contract with the
    /// deeper layers, every line optional so a partial/garbled response still
    /// parses whatever it got right.
    public static let systemCore = """
        You write Osmo's per-conversation intel. Given one conversation and what's \
        known about the person, return these lines — every one OPTIONAL, include \
        only what the conversation actually supports, never invent:
        TOPIC: a 1-3 word label for what this conversation is about
        BRIEF: one line (max 20 words) that instantly re-orients the user — what \
        this thread is about right now, what they owe or promised, or the smart \
        angle for the reply
        URGENCY: none, soon, today, or overdue — then a dash and a short reason \
        (only if a real deadline or time pressure is evident)
        ACTION: the single best word for what's owed — reply, decide, schedule, \
        pay, task, or fyi
        QUESTION: yes if their last message asked something still unanswered, \
        else no
        COMMITMENTS: things the USER (not them) promised or said they'd do, \
        semicolon-separated, at most 2, each under 10 words
        TONE: 1-2 words for their tone on their last message (e.g. warm, terse, \
        excited, annoyed)
        TEMP: warm, neutral, or cool — the overall feel of the thread lately
        EFFORT: quick or thoughtful — how much thought a good reply needs
        AUTOMATED: yes if this reads like a bot/newsletter/notification rather \
        than a person, else no
        No preamble, no quotation marks, no emoji. Use exactly these line labels.
        """

    public static func compose(_ ctx: InsightContext, now: Date = Date()) -> ComposedPrompt {
        var s: [String] = []
        s.append("WHO: \(ctx.personName)")
        if let g = ctx.goalText, !g.isEmpty { s.append("YOUR GOAL WITH THEM: \(g)") }
        if let m = ctx.memoryNote, !m.isEmpty { s.append("WHAT YOU KNOW: \(m.prefix(300))") }
        if let t = ctx.trajectoryDriver { s.append("TREND: \(t)") }
        if let v = ctx.verdictDetail { s.append("TIMING: \(v)") }
        if !ctx.transcript.isEmpty {
            s.append("CONVERSATION (most recent last):")
            s.append(ctx.transcript.suffix(10)
                .map { ($0.fromMe ? "You: " : "Them: ") + $0.text }
                .joined(separator: "\n"))
        }
        // In the volatile (uncached) turn — URGENCY: today is unanswerable
        // without knowing what "today" is, and this must not touch systemCore
        // or every thread would miss the prompt cache.
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d"
        s.append("TODAY IS: \(df.string(from: now))")
        s.append("Write the lines that apply.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }

    /// Tolerant line-prefix scan — same style as `Insight.parseResult`. Unknown
    /// enum raw values are dropped (nil), not treated as parse failures; a bare
    /// unlabeled line (legacy cache / loose model) is kept as the brief.
    public static func parseResult(_ raw: String) -> ThreadIntel? {
        var intel = ThreadIntel()
        var sawAnyLine = false
        var sawTopic = false

        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()

            if lower.hasPrefix("topic:") {
                let v = Insight.clean(String(t.dropFirst(6)))
                if !v.isEmpty, v.split(separator: " ").count <= 3, v.count <= 28 { intel.topic = v }
                sawAnyLine = true; sawTopic = true
            } else if lower.hasPrefix("brief:") {
                let v = Insight.clean(String(t.dropFirst(6)))
                if !v.isEmpty { intel.brief = v }
                sawAnyLine = true
            } else if lower.hasPrefix("urgency:") {
                let v = Insight.clean(String(t.dropFirst(8)))
                let parts = v.split(separator: "—", maxSplits: 1).flatMap { $0.split(separator: "-", maxSplits: 1) }
                let level = parts.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                intel.urgency = IntelUrgency(rawValue: level)
                if parts.count > 1 {
                    let reason = parts[1].trimmingCharacters(in: .whitespaces)
                    intel.urgencyReason = reason.isEmpty ? nil : reason
                }
                sawAnyLine = true
            } else if lower.hasPrefix("action:") {
                let v = Insight.clean(String(t.dropFirst(7))).lowercased()
                intel.action = IntelAction(rawValue: v)
                sawAnyLine = true
            } else if lower.hasPrefix("question:") {
                let v = Insight.clean(String(t.dropFirst(9))).lowercased()
                if v.hasPrefix("y") { intel.openQuestion = true }
                else if v.hasPrefix("n") { intel.openQuestion = false }
                sawAnyLine = true
            } else if lower.hasPrefix("commitments:") {
                let v = Insight.clean(String(t.dropFirst(12)))
                let items = v.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                intel.commitments = Array(items.prefix(2))
                sawAnyLine = true
            } else if lower.hasPrefix("tone:") {
                let v = Insight.clean(String(t.dropFirst(5)))
                if !v.isEmpty { intel.tone = v }
                sawAnyLine = true
            } else if lower.hasPrefix("temp:") {
                let v = Insight.clean(String(t.dropFirst(5))).lowercased()
                intel.temperature = IntelTemperature(rawValue: v)
                sawAnyLine = true
            } else if lower.hasPrefix("effort:") {
                let v = Insight.clean(String(t.dropFirst(7))).lowercased()
                intel.effort = IntelEffort(rawValue: v)
                sawAnyLine = true
            } else if lower.hasPrefix("automated:") {
                let v = Insight.clean(String(t.dropFirst(10))).lowercased()
                if v.hasPrefix("y") { intel.automated = true }
                else if v.hasPrefix("n") { intel.automated = false }
                sawAnyLine = true
            } else if intel.brief == nil, !lower.contains(":") {
                // Bare line = the brief (legacy cache / loose model output).
                let v = Insight.clean(t)
                if !v.isEmpty { intel.brief = v; sawAnyLine = true }
            }
        }
        _ = sawTopic
        return sawAnyLine ? intel : nil
    }
}

extension SuggestionService {
    /// The full thread intel (single completion) — the one call replacing
    /// `insight(_:)` in the app's per-thread cache.
    public func threadIntel(_ ctx: InsightContext, now: Date = Date()) async throws -> ThreadIntel {
        let prompt = ThreadIntelBrain.compose(ctx, now: now)
        let raw = try await generator.generate(
            systemCore: prompt.systemCore, userTurn: prompt.userTurn, count: 1)
        guard let result = ThreadIntelBrain.parseResult(raw) else { throw GenerationError.empty }
        return result
    }
}
