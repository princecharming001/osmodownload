import Foundation

/// One turn of a conversation handed to the engine. The app builds these from
/// `OsmoMessage` rows (or the overlay's screen-read); the engine stays decoupled
/// from storage.
public struct ThreadTurn: Equatable, Sendable {
    public var fromMe: Bool
    public var text: String
    public var sentAt: Date?
    /// Who sent this turn (display name) — set for GROUP threads so prompt
    /// renderers can label each speaker; nil in 1:1 threads (or when unknown),
    /// where "Them" is unambiguous.
    public var senderName: String?
    /// Real read-receipt time where the platform exposes it (iMessage
    /// `date_read`, carried on `OsmoMessage.readAt`). For MY messages this is
    /// when THEY read it (deliberation vs neglect); nil when the platform
    /// doesn't expose receipts or hasn't been read yet. Additive + defaulted so
    /// every existing `ThreadTurn(...)` call site is unaffected.
    public var readAt: Date?

    public init(fromMe: Bool, text: String, sentAt: Date? = nil,
                senderName: String? = nil, readAt: Date? = nil) {
        self.fromMe = fromMe
        self.text = text
        self.sentAt = sentAt
        self.senderName = senderName
        self.readAt = readAt
    }
}

/// A structural read of the real conversation — the thing a keyboard app reading
/// one screenshot could never do. Drives Linguistic Style Matching, momentum
/// awareness, and "answer their question first" behavior. Pure and testable.
public struct ThreadRead: Equatable, Sendable {
    public enum Ball: Equatable, Sendable { case mine, theirs, empty }

    /// Whose turn it is — the last speaker determines who owes a reply.
    public var ball: Ball
    /// Their most recent message (nil if the last was mine or the thread is empty).
    public var theirLastText: String?
    /// LSM features of their last message.
    public var wordCount: Int
    public var mostlyLowercase: Bool
    public var usesEmoji: Bool
    public var exclaims: Bool
    public var asksQuestion: Bool
    /// Their message left a question hanging that the reply should answer first.
    public var hasOpenQuestion: Bool
    /// Coarse sentiment from keywords: -1 negative … +1 positive.
    public var sentiment: Double
    /// How long since the last message, if timestamps are present.
    public var idle: TimeInterval?
    /// The user has been carrying the thread (sent the last N without reply).
    public var userCarrying: Bool

    public static func read(_ turns: [ThreadTurn], now: Date = Date()) -> ThreadRead {
        guard let last = turns.last else {
            return ThreadRead(ball: .empty, theirLastText: nil, wordCount: 0,
                              mostlyLowercase: false, usesEmoji: false, exclaims: false,
                              asksQuestion: false, hasOpenQuestion: false, sentiment: 0,
                              idle: nil, userCarrying: false)
        }
        let ball: Ball = last.fromMe ? .mine : .theirs
        let theirLast = turns.last(where: { !$0.fromMe })
        let feat = theirLast.map(features) ?? .empty

        // User carrying: the last two turns are both mine (they went quiet).
        let tail = turns.suffix(2)
        let userCarrying = tail.count == 2 && tail.allSatisfy(\.fromMe)

        let idle: TimeInterval? = last.sentAt.map { now.timeIntervalSince($0) }

        return ThreadRead(
            ball: ball,
            theirLastText: theirLast?.text,
            wordCount: feat.wordCount,
            mostlyLowercase: feat.mostlyLowercase,
            usesEmoji: feat.usesEmoji,
            exclaims: feat.exclaims,
            asksQuestion: feat.asksQuestion,
            hasOpenQuestion: ball == .theirs && feat.asksQuestion,
            sentiment: feat.sentiment,
            idle: idle,
            userCarrying: userCarrying)
    }

    private struct Features {
        var wordCount = 0
        var mostlyLowercase = false
        var usesEmoji = false
        var exclaims = false
        var asksQuestion = false
        var sentiment = 0.0
        static let empty = Features()
    }

    private static func features(_ turn: ThreadTurn) -> Features {
        let t = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = t.split { $0 == " " || $0 == "\n" }.count
        let letters = t.filter(\.isLetter)
        let uppers = letters.filter(\.isUppercase)
        let lower = letters.isEmpty ? false : Double(uppers.count) / Double(letters.count) < 0.05
        let emoji = t.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        return Features(
            wordCount: words,
            mostlyLowercase: lower,
            usesEmoji: emoji,
            exclaims: t.contains("!"),
            asksQuestion: t.contains("?"),
            sentiment: sentiment(t.lowercased()))
    }

    private static let positive = ["thanks", "great", "love", "awesome", "yes", "excited",
                                   "happy", "good", "appreciate", "perfect", "haha", "lol", "😊", "❤️"]
    private static let negative = ["no", "not", "sorry", "unfortunately", "can't", "cant",
                                   "won't", "wont", "disappointed", "upset", "angry", "frustrated",
                                   "annoyed", "hurt", "sad", "ugh", "stressed"]

    private static func sentiment(_ text: String) -> Double {
        var score = 0.0
        for w in positive where text.contains(w) { score += 1 }
        for w in negative where text.contains(w) { score -= 1 }
        return max(-1, min(1, score / 3))
    }
}
