import Foundation
import OsmoCore

/// Judges a draft the user is about to send — the pill's "Analyze" flow.
/// Answers exactly what someone staring at a half-typed message wants to know:
/// is this good, what could go wrong, and what else could I say instead.
public struct JudgeContext: Sendable {
    public var draft: String
    public var personName: String
    public var platform: Platform
    public var toneHint: String?
    public var userIntent: String?
    public var partnerDirectives: [String]
    public var goalText: String?
    /// Caller passes a bounded tail (suffix(12)) — the recent shape of the
    /// conversation, not the whole history.
    public var transcript: [ThreadTurn]

    public init(draft: String, personName: String, platform: Platform, toneHint: String? = nil,
                userIntent: String? = nil, partnerDirectives: [String] = [], goalText: String? = nil,
                transcript: [ThreadTurn] = []) {
        self.draft = draft; self.personName = personName; self.platform = platform
        self.toneHint = toneHint; self.userIntent = userIntent
        self.partnerDirectives = partnerDirectives; self.goalText = goalText
        self.transcript = transcript
    }
}

public enum MessageJudge {
    public static let systemCore = """
        You judge a draft message the user is about to send, before they send it. \
        Given the draft, who it's to, how that person communicates, and the \
        recent conversation, return:
        SCORE: a number 0-10 for how good this message is as a reply right now
        WORKS: up to 3 dash-bullet reasons it works, each on its own line
        RISKS: up to 3 dash-bullet reasons it could land badly or misses \
        something, each on its own line
        ALT1: a short label, a dash, then a full rewritten alternative message
        ALT2: a different short label, a dash, then a different full rewrite
        Ground every point in the actual draft and conversation — never invent \
        facts about the person. No preamble, no quotation marks, no emoji.
        """

    public static func compose(_ ctx: JudgeContext) -> ComposedPrompt {
        var s: [String] = []
        s.append("TO: \(ctx.personName) (\(ctx.platform.displayName))")
        if !ctx.partnerDirectives.isEmpty {
            s.append("HOW THEY COMMUNICATE: \(ctx.partnerDirectives.joined(separator: " "))")
        }
        if let g = ctx.goalText, !g.isEmpty { s.append("YOUR GOAL: \(g)") }
        if let hint = ctx.toneHint, !hint.isEmpty { s.append("TONE TO AIM FOR: \(hint)") }
        if let intent = ctx.userIntent, !intent.trimmingCharacters(in: .whitespaces).isEmpty {
            s.append("WHAT YOU'RE TRYING TO SAY: \(intent)")
        }
        if !ctx.transcript.isEmpty {
            s.append("RECENT CONVERSATION (most recent last):")
            s.append(ctx.transcript.suffix(12)
                .map { ($0.fromMe ? "You: " : "\(($0.senderName ?? "Them")): ") + $0.text }
                .joined(separator: "\n"))
        }
        s.append("THE DRAFT:\n\(ctx.draft)")
        s.append("Judge it.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }

    public struct Alternative: Equatable, Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) { self.label = label; self.text = text }
    }

    public struct Result: Equatable, Sendable {
        public var score: Int?
        public var works: [String]
        public var risks: [String]
        public var alternatives: [Alternative]
        public init(score: Int? = nil, works: [String] = [], risks: [String] = [],
                    alternatives: [Alternative] = []) {
            self.score = score; self.works = works; self.risks = risks; self.alternatives = alternatives
        }
    }

    /// Tolerant parse: SCORE accepts "7", "7/10", "Score - 7"; WORKS/RISKS
    /// accept bullets on the header line or on following dash/bullet lines;
    /// ALT1/ALT2 accept "ALT1:", "Alternative 1:" with a dash/colon splitting
    /// label from rewrite. Returns nil only when nothing at all matched.
    public static func parseResult(_ raw: String) -> Result? {
        var result = Result()
        var sawAny = false
        var section = 0   // 0 = none, 1 = works, 2 = risks

        for rawLine in raw.components(separatedBy: .newlines) {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()

            if lower.hasPrefix("score") {
                result.score = firstInt(in: t)
                sawAny = true; section = 0
                continue
            }
            if lower.hasPrefix("works") {
                section = 1; sawAny = true
                appendInlineBullet(after: "works", from: t, to: &result.works)
                continue
            }
            if lower.hasPrefix("risks") {
                section = 2; sawAny = true
                appendInlineBullet(after: "risks", from: t, to: &result.risks)
                continue
            }
            if lower.hasPrefix("alt1") || lower.hasPrefix("alternative 1") || lower.hasPrefix("alternative1") {
                if let alt = parseAlt(t) { result.alternatives.append(alt); sawAny = true }
                section = 0
                continue
            }
            if lower.hasPrefix("alt2") || lower.hasPrefix("alternative 2") || lower.hasPrefix("alternative2") {
                if let alt = parseAlt(t) { result.alternatives.append(alt); sawAny = true }
                section = 0
                continue
            }
            if section == 1, t.first.map({ "-•".contains($0) }) == true {
                appendBullet(t, to: &result.works); sawAny = true
            } else if section == 2, t.first.map({ "-•".contains($0) }) == true {
                appendBullet(t, to: &result.risks); sawAny = true
            }
        }
        result.works = Array(result.works.prefix(3))
        result.risks = Array(result.risks.prefix(3))
        return sawAny ? result : nil
    }

    private static func firstInt(in s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        guard let n = Int(digits) else { return nil }
        return min(10, max(0, n))
    }

    private static func appendBullet(_ raw: String, to list: inout [String]) {
        var t = raw
        while let first = t.first, "-•".contains(first) {
            t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces)
        }
        if !t.isEmpty { list.append(t) }
    }

    /// Handles a header that carries its first bullet inline: "WORKS: - short".
    private static func appendInlineBullet(after header: String, from line: String, to list: inout [String]) {
        guard let colonIdx = line.firstIndex(of: ":") else { return }
        let inline = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        if !inline.isEmpty { appendBullet(inline, to: &list) }
    }

    static func parseAlt(_ line: String) -> Alternative? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let afterColon = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        for sep in ["—", " - ", ": "] {
            if let range = afterColon.range(of: sep) {
                let label = String(afterColon[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let text = String(afterColon[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty, !text.isEmpty { return Alternative(label: label, text: text) }
            }
        }
        guard !afterColon.isEmpty else { return nil }
        return Alternative(label: "Alternative", text: afterColon)
    }

    /// Fold ToneCheck's deterministic flags into RISKS — skip anything the
    /// model already covered (matched by title substring), clamp to 4 total.
    public static func merge(_ result: Result, toneCheck: ToneCheck) -> Result {
        var merged = result
        for flag in toneCheck.flags {
            let entry = "\(flag.title) — \(flag.detail)"
            let alreadyCovered = merged.risks.contains { $0.lowercased().contains(flag.title.lowercased()) }
            if !alreadyCovered { merged.risks.append(entry) }
        }
        merged.risks = Array(merged.risks.prefix(4))
        return merged
    }
}

extension SuggestionService {
    /// Score + why-it-works + risks + alternatives, one completion.
    public func judge(_ ctx: JudgeContext) async throws -> MessageJudge.Result {
        let prompt = MessageJudge.compose(ctx)
        let raw = try await generator.generate(
            systemCore: prompt.systemCore, userTurn: prompt.userTurn, count: 1)
        guard let result = MessageJudge.parseResult(raw) else { throw GenerationError.empty }
        return result
    }
}
