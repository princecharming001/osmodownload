import Foundation
import GRDB

/// A tapback reaction on a message (iMessage ❤️👍👎😂‼️❓ or an arbitrary emoji).
/// Stored in its own table so a reaction row is NEVER rendered as a message
/// bubble — it's folded onto the target message for display. Locally derived from
/// chat.db, so not a synced entity. The `id` is deterministic over
/// (target, reactor, type) so an add → remove → re-add of the same tapback
/// converges on one row and a remove can delete exactly the matching add.
public struct MessageReaction: Codable, Equatable, Sendable, Identifiable,
                               FetchableRecord, PersistableRecord {
    public var id: UUID
    /// The message this reacts to (Osmo message id derived from the target guid).
    public var targetMessageID: UUID
    /// Who reacted (contact id); nil when it's the user (isFromMe).
    public var reactorContactID: UUID?
    /// A stable kind: heart / like / dislike / laugh / emphasis / question / emoji.
    public var reactionType: String
    /// The glyph to show (a canonical tapback emoji, or the custom emoji).
    public var emoji: String
    public var isFromMe: Bool
    public var reactedAt: Date

    public static let databaseTableName = "message_reaction"

    public init(id: UUID, targetMessageID: UUID, reactorContactID: UUID?,
                reactionType: String, emoji: String, isFromMe: Bool, reactedAt: Date) {
        self.id = id
        self.targetMessageID = targetMessageID
        self.reactorContactID = reactorContactID
        self.reactionType = reactionType
        self.emoji = emoji
        self.isFromMe = isFromMe
        self.reactedAt = reactedAt
    }

    /// Deterministic id so add + remove of the same tapback resolve to one row.
    public static func makeID(targetGuid: String, reactorKey: String, type: String) -> UUID {
        DeterministicID.forPlatform(.imessage, kind: "reaction",
                                    key: "\(targetGuid)|\(reactorKey)|\(type)")
    }
}

/// The tapback vocabulary + how Apple's `associated_message_type` maps to it.
/// 2000–2005 add a tapback, 3000–3005 remove it; 2006/3006 carry an arbitrary
/// emoji in `associated_message_emoji`.
public enum Tapback {
    /// (stableType, emoji) for a canonical tapback code, or nil if not a tapback.
    public static func kind(forAssociatedType type: Int) -> (type: String, emoji: String)? {
        switch type % 1000 {          // 2000 and 3000 share the low 3 digits
        case 0: return ("heart", "❤️")
        case 1: return ("like", "👍")
        case 2: return ("dislike", "👎")
        case 3: return ("laugh", "😂")
        case 4: return ("emphasis", "‼️")
        case 5: return ("question", "❓")
        default: return nil
        }
    }
    public static func isAdd(_ type: Int) -> Bool { (2000...2006).contains(type) }
    public static func isRemove(_ type: Int) -> Bool { (3000...3006).contains(type) }
    public static func isReaction(_ type: Int) -> Bool { isAdd(type) || isRemove(type) }

    /// The six one-tap choices offered when the user sends a reaction.
    public static let choices: [(type: String, emoji: String)] = [
        ("heart", "❤️"), ("like", "👍"), ("dislike", "👎"),
        ("laugh", "😂"), ("emphasis", "‼️"), ("question", "❓"),
    ]
}
