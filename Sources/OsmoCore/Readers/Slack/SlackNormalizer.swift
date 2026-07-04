import Foundation

/// A Slack message from `conversations.history` (subset).
public struct SlackMessage: Decodable, Sendable {
    public var ts: String            // "1700000000.001200" — seconds.micros, also the id
    public var user: String?         // sender user id
    public var text: String?
}

/// One Slack conversation's messages + metadata for normalization.
public struct SlackConversation: Sendable {
    public var id: String            // channel/DM id
    public var name: String?         // DM peer name or channel name
    public var isGroup: Bool
    public var peerUserID: String?   // for a 1:1 DM, the other user's id
    public var messages: [SlackMessage]
    public init(id: String, name: String? = nil, isGroup: Bool = false,
                peerUserID: String? = nil, messages: [SlackMessage]) {
        self.id = id; self.name = name; self.isGroup = isGroup
        self.peerUserID = peerUserID; self.messages = messages
    }
}

/// Maps Slack conversations into the canonical schema. `selfUserID` sets direction.
public enum SlackNormalizer {
    private static let platform = Platform.slack

    public static func normalize(_ conversations: [SlackConversation], selfUserID: String) -> NormalizedBatch {
        var contacts: [UUID: OsmoContact] = [:]
        var threads: [OsmoThread] = []
        var out: [OsmoMessage] = []
        let epoch = Date(timeIntervalSince1970: 0)

        for convo in conversations {
            let threadID = OsmoThread.makeID(platform: platform, platformThreadID: convo.id)
            let times = convo.messages.compactMap { Double($0.ts) }.map { Date(timeIntervalSince1970: $0) }
            threads.append(OsmoThread(id: threadID, updatedAt: epoch, deviceSeq: 0,
                                      platform: platform, platformThreadID: convo.id,
                                      title: convo.name, isGroup: convo.isGroup,
                                      lastMessageAt: times.max()))

            for m in convo.messages {
                let sentAt = Double(m.ts).map { Date(timeIntervalSince1970: $0) } ?? epoch
                let isFromMe = m.user == selfUserID
                var senderContactID: UUID?
                if let user = m.user, user != selfUserID {
                    let cid = OsmoContact.makeID(platform: platform, handle: user)
                    if contacts[cid] == nil {
                        // Name a 1:1 peer from the conversation; group senders stay id-only until enriched.
                        let name = (!convo.isGroup && convo.peerUserID == user) ? convo.name : nil
                        contacts[cid] = OsmoContact(id: cid, updatedAt: epoch, deviceSeq: 0,
                                                    platform: platform, handle: user,
                                                    displayName: name, isMe: false)
                    }
                    senderContactID = cid
                }
                out.append(OsmoMessage(
                    id: OsmoMessage.makeID(platform: platform, platformMessageID: "\(convo.id):\(m.ts)"),
                    updatedAt: epoch, deviceSeq: 0, platform: platform,
                    platformMessageID: "\(convo.id):\(m.ts)", threadID: threadID,
                    senderContactID: senderContactID, isFromMe: isFromMe,
                    text: m.text ?? "", sentAt: sentAt))
            }
        }

        return NormalizedBatch(contacts: Array(contacts.values), threads: threads, messages: out)
    }
}
