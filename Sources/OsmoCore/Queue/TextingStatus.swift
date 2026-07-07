import Foundation

/// A compact snapshot of where one thread stands, built by the app from the store
/// (last message direction/time + the real read receipt on the user's last
/// message). Because Osmo reads the actual `chat.db` `date_read`, "left on read"
/// is a **fact** here, not the inference a screenshot-only app was stuck with.
public struct ThreadSnapshot: Equatable, Sendable {
    public var threadID: UUID
    public var personID: UUID?
    public var personName: String
    public var platform: Platform
    public var isEmpty: Bool
    /// True when the user sent the last message.
    public var lastFromMe: Bool
    public var lastMessageAt: Date?
    /// When *they* read the user's last message, if a read receipt exists.
    public var myLastReadByThem: Date?
    public var theirLastText: String?
    /// Whether this looks like a genuine conversation with a person (vs. an OTP
    /// bot, marketing blast, no-reply notification…). Defaults true so a snapshot
    /// built without classification is treated as human.
    public var isLikelyHuman: Bool
    /// Short reason it was judged non-human (for the "why hidden" affordance).
    public var nonHumanReason: String?

    public init(threadID: UUID, personID: UUID? = nil, personName: String,
                platform: Platform, isEmpty: Bool = false, lastFromMe: Bool,
                lastMessageAt: Date? = nil, myLastReadByThem: Date? = nil,
                theirLastText: String? = nil,
                isLikelyHuman: Bool = true, nonHumanReason: String? = nil) {
        self.threadID = threadID
        self.personID = personID
        self.personName = personName
        self.platform = platform
        self.isEmpty = isEmpty
        self.lastFromMe = lastFromMe
        self.lastMessageAt = lastMessageAt
        self.myLastReadByThem = myLastReadByThem
        self.theirLastText = theirLastText
        self.isLikelyHuman = isLikelyHuman
        self.nonHumanReason = nonHumanReason
    }
}

/// Where a conversation stands. Drives the people grid pills and the morning queue.
public enum TextingStatus: String, Equatable, Sendable {
    case needsReply     // they're waiting on you
    case leftOnRead     // you're waiting, they read it and didn't reply (FACT via read receipt)
    case waiting        // you're waiting, not yet read (or no receipt)
    case ghosted        // you're waiting, long silence
    case quiet          // dormant, nobody owes anybody
    case sayHi          // no history

    public var label: String {
        switch self {
        case .needsReply: return "your turn"
        case .leftOnRead: return "left on read"
        case .waiting: return "waiting"
        case .ghosted: return "gone quiet"
        case .quiet: return "quiet"
        case .sayHi: return "say hi"
        }
    }

    public struct Config: Sendable {
        public var leftOnRead: TimeInterval
        public var ghosted: TimeInterval
        public var quiet: TimeInterval
        public init(leftOnRead: TimeInterval = 3 * 3600,
                    ghosted: TimeInterval = 3 * 86_400,
                    quiet: TimeInterval = 21 * 86_400) {
            self.leftOnRead = leftOnRead; self.ghosted = ghosted; self.quiet = quiet
        }
    }

    public static func derive(_ s: ThreadSnapshot, now: Date = Date(),
                              config: Config = .init()) -> TextingStatus {
        if s.isEmpty { return .sayHi }
        let idle = s.lastMessageAt.map { now.timeIntervalSince($0) } ?? 0
        if !s.lastFromMe { return .needsReply }
        // Your message is last.
        if idle > config.quiet { return .quiet }
        if idle > config.ghosted { return .ghosted }
        if let read = s.myLastReadByThem, now.timeIntervalSince(read) > config.leftOnRead {
            return .leftOnRead
        }
        return .waiting
    }
}
