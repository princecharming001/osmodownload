import Foundation
import OsmoCore

/// How the USER themselves texts — the Wispr-Flow-style "your voice" profile.
/// Reuses `PartnerProfile`'s exact stat math (median-reply-gap, active-block
/// bucketing), inverted onto the user's own outbound turns, so "how you sound"
/// and "how they sound" are computed by the same honest yardstick.
public struct VoiceStats: Equatable, Sendable {
    public struct Sub: Equatable, Sendable {
        public var msgCount: Int
        public var avgWords: Int
        public var lowercaseShare: Double
        public var emojiRate: Double
        public var endPunctRate: Double     // share ending in . ! ?
        public var exclamRate: Double
        public var questionRate: Double
        public init(msgCount: Int = 0, avgWords: Int = 0, lowercaseShare: Double = 0,
                    emojiRate: Double = 0, endPunctRate: Double = 0, exclamRate: Double = 0,
                    questionRate: Double = 0) {
            self.msgCount = msgCount; self.avgWords = avgWords; self.lowercaseShare = lowercaseShare
            self.emojiRate = emojiRate; self.endPunctRate = endPunctRate
            self.exclamRate = exclamRate; self.questionRate = questionRate
        }
        public static let empty = Sub()
    }

    public var overall: Sub
    public var medianReplySeconds: TimeInterval?
    public var activeBlock: String?
    public var topPhrases: [String]
    public var perPlatform: [Platform: Sub]

    /// Not enough sent messages to say anything honest yet.
    public var isEmpty: Bool { overall.msgCount < 20 }

    public init(overall: Sub, medianReplySeconds: TimeInterval?, activeBlock: String?,
                topPhrases: [String], perPlatform: [Platform: Sub]) {
        self.overall = overall; self.medianReplySeconds = medianReplySeconds
        self.activeBlock = activeBlock; self.topPhrases = topPhrases; self.perPlatform = perPlatform
    }

    /// `turnsByPlatform` — the caller pre-buckets (`ThreadTurn` carries no
    /// platform of its own).
    public static func compute(_ turnsByPlatform: [Platform: [ThreadTurn]]) -> VoiceStats {
        let allTurns = turnsByPlatform.values.flatMap { $0 }
        let overall = sub(from: allTurns)
        var perPlatform: [Platform: Sub] = [:]
        for (platform, turns) in turnsByPlatform {
            let s = sub(from: turns)
            if s.msgCount > 0 { perPlatform[platform] = s }
        }

        // Invert fromMe so PartnerProfile's "my message → their reply" gap
        // math instead measures "their message → MY reply" — the user's own
        // reply speed, by the identical yardstick used for everyone else.
        let inverted = allTurns.map { ThreadTurn(fromMe: !$0.fromMe, text: $0.text, sentAt: $0.sentAt) }
        let medianReplySeconds = PartnerProfile.medianReplyGap(inverted)
        let myTurns = allTurns.filter(\.fromMe)
        let activeBlock = PartnerProfile.readActiveBlock(myTurns)
        let topPhrases = extractTopPhrases(myTurns.map(\.text))

        return VoiceStats(overall: overall, medianReplySeconds: medianReplySeconds,
                          activeBlock: activeBlock, topPhrases: topPhrases, perPlatform: perPlatform)
    }

    private static func sub(from turns: [ThreadTurn]) -> Sub {
        let mine = turns.filter(\.fromMe)
        let texts = mine.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let n = texts.count
        guard n > 0 else { return .empty }
        func share(_ predicate: (String) -> Bool) -> Double {
            Double(texts.filter(predicate).count) / Double(n)
        }
        let lettered = texts.filter { $0.contains(where: \.isLetter) }
        let lowercase = lettered.isEmpty ? 0
            : Double(lettered.filter { $0 == $0.lowercased() }.count) / Double(lettered.count)
        return Sub(
            msgCount: n,
            avgWords: texts.map { $0.split(separator: " ").count }.reduce(0, +) / n,
            lowercaseShare: lowercase,
            emojiRate: share { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } },
            endPunctRate: share { $0.last == "." || $0.last == "!" || $0.last == "?" },
            exclamRate: share { $0.contains("!") },
            questionRate: share { $0.contains("?") })
    }

    // MARK: - Signature phrases

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with",
        "is", "are", "was", "were", "be", "been", "i", "you", "it", "that", "this", "my",
        "your", "me", "so", "just", "if", "not", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "im", "ill", "its", "dont", "yeah", "yea", "ok", "okay",
    ]

    /// 2–3-word phrases the user actually repeats — stopword-filtered, counted
    /// once per message (a phrase twice in one message isn't "said more"), ≥3
    /// distinct messages, deterministic ordering (count desc, then alphabetical).
    static func extractTopPhrases(_ texts: [String], max: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        for raw in texts {
            let cleaned = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            let words = cleaned.split(separator: " ").map(String.init)
            guard words.count >= 3 else { continue }
            var seenInMessage = Set<String>()
            for n in [2, 3] where words.count >= n {
                for i in 0...(words.count - n) {
                    let gram = Array(words[i..<(i + n)])
                    if gram.contains(where: { $0.contains(where: \.isNumber) }) { continue }
                    if gram.allSatisfy({ stopwords.contains($0) }) { continue }
                    seenInMessage.insert(gram.joined(separator: " "))
                }
            }
            for phrase in seenInMessage { counts[phrase, default: 0] += 1 }
        }
        return counts.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(max).map(\.key)
    }
}

/// The AI-written narrative half — three short paragraphs describing the
/// user's texting persona, grounded only in their own stats and sample lines.
public enum VoicePersona {
    public static let systemCore = """
        You write a short texting-persona profile for the user, based only on \
        statistics about their own messages and a handful of real sample lines. \
        Return EXACTLY three short paragraphs, in this order, no headers, no \
        preamble, no quotation marks, no emoji:
        1. Their style — length, tone, punctuation/emoji habits, formality.
        2. How they adapt — differences across platforms or people, if the data \
        shows any; otherwise note that their voice stays consistent.
        3. Their signature moves — repeated phrases or habits that are distinctly \
        theirs.
        Ground every claim in the numbers or lines given. Never flatter, never \
        invent. Plain, observational sentences.
        """

    public static func compose(stats: VoiceStats, sampleLines: [String]) -> ComposedPrompt {
        var s: [String] = []
        s.append("MESSAGES SENT: \(stats.overall.msgCount)")
        s.append("AVG WORDS: \(stats.overall.avgWords)")
        s.append("LOWERCASE SHARE: \(Int(stats.overall.lowercaseShare * 100))%")
        s.append("EMOJI RATE: \(Int(stats.overall.emojiRate * 100))%")
        s.append("EXCLAMATION RATE: \(Int(stats.overall.exclamRate * 100))%")
        s.append("QUESTION RATE: \(Int(stats.overall.questionRate * 100))%")
        if let m = stats.medianReplySeconds { s.append("TYPICAL REPLY SPEED: \(PartnerProfile.humanGap(m))") }
        if let block = stats.activeBlock { s.append("MOST ACTIVE: \(block)") }
        if !stats.perPlatform.isEmpty {
            s.append("PER-PLATFORM AVG WORDS: " + stats.perPlatform
                .map { "\($0.key.rawValue)=\($0.value.avgWords)" }.sorted().joined(separator: ", "))
        }
        if !stats.topPhrases.isEmpty {
            s.append("REPEATED PHRASES: \(stats.topPhrases.joined(separator: ", "))")
        }
        if !sampleLines.isEmpty {
            s.append("SAMPLE LINES:")
            s.append(sampleLines.suffix(20).map { "- \($0)" }.joined(separator: "\n"))
        }
        s.append("Write the three paragraphs.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }

    public struct Result: Equatable, Sendable {
        public var paragraphs: [String]
        public init(paragraphs: [String]) { self.paragraphs = paragraphs }
    }

    /// Blank-line (or single-newline, when the model skips the blank) paragraph
    /// split; headers optional; clamps to 3.
    public static func parseResult(_ raw: String) -> Result? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var chunks = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if chunks.count < 2 {
            chunks = normalized.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let cleaned = chunks.map { line -> String in
            var t = line
            for prefix in ["1.", "2.", "3.", "-", "•"] where t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return t
        }
        guard !cleaned.isEmpty else { return nil }
        return Result(paragraphs: Array(cleaned.prefix(3)))
    }

    /// Deterministic fallback, built from the same directive style as
    /// `VoiceProfile` — never blank, keyless-safe.
    public static func fallback(_ stats: VoiceStats) -> Result {
        guard !stats.isEmpty else {
            return Result(paragraphs: ["Not enough sent messages yet to read your voice."])
        }
        var style = "You write about \(max(stats.overall.avgWords, 1)) words per message"
        style += stats.overall.lowercaseShare > 0.6 ? ", mostly lowercase" : ""
        style += stats.overall.emojiRate > 0.3 ? ", with emoji often" : stats.overall.emojiRate < 0.05 ? ", rarely with emoji" : ""
        style += "."
        var adapt = "Your voice looks steady across where you text."
        if let widest = stats.perPlatform.max(by: { $0.value.avgWords < $1.value.avgWords }),
           let narrowest = stats.perPlatform.min(by: { $0.value.avgWords < $1.value.avgWords }),
           widest.key != narrowest.key, widest.value.avgWords - narrowest.value.avgWords >= 5 {
            adapt = "You write longer on \(widest.key.displayName) than on \(narrowest.key.displayName)."
        }
        let moves = stats.topPhrases.isEmpty
            ? "No standout repeated phrases yet."
            : "You reach for \"\(stats.topPhrases.prefix(3).joined(separator: "\", \""))\" often."
        return Result(paragraphs: [style, adapt, moves])
    }
}

extension SuggestionService {
    public func voicePersona(stats: VoiceStats, sampleLines: [String]) async throws -> VoicePersona.Result {
        let prompt = VoicePersona.compose(stats: stats, sampleLines: sampleLines)
        let raw = try await generator.generate(
            systemCore: prompt.systemCore, userTurn: prompt.userTurn, count: 1)
        guard let result = VoicePersona.parseResult(raw) else { throw GenerationError.empty }
        return result
    }
}
