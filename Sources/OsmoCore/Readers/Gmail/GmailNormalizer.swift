import Foundation

/// A Gmail message as the API returns it (subset). Decodes `users.messages.get`
/// JSON directly.
public struct GmailMessage: Decodable, Sendable {
    public var id: String
    public var threadId: String
    public var internalDate: String?     // ms since epoch, as a string
    public var snippet: String?
    public var payload: Payload?

    public struct Payload: Decodable, Sendable {
        public var headers: [Header]?
    }
    public struct Header: Decodable, Sendable {
        public var name: String
        public var value: String
    }

    public func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value
    }
}

/// Maps Gmail messages into the canonical schema. Pure + fixture-tested. The
/// "other party" (the person the thread is *with*) becomes the contact;
/// `selfEmail` decides direction.
public enum GmailNormalizer {
    private static let platform = Platform.gmail

    public static func normalize(_ messages: [GmailMessage], selfEmail: String) -> NormalizedBatch {
        let me = selfEmail.lowercased()
        var contacts: [UUID: OsmoContact] = [:]
        var threads: [UUID: OsmoThread] = [:]
        var out: [OsmoMessage] = []
        let epoch = Date(timeIntervalSince1970: 0)

        for m in messages {
            let fromRaw = m.header("From") ?? ""
            let fromEmail = EmailAddress.extract(fromRaw)
            let isFromMe = fromEmail == me
            let sentAt = m.internalDate.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } ?? epoch
            let subject = m.header("Subject")

            let threadID = OsmoThread.makeID(platform: platform, platformThreadID: m.threadId)
            if var t = threads[threadID] {
                if sentAt > (t.lastMessageAt ?? .distantPast) { t.lastMessageAt = sentAt; threads[threadID] = t }
            } else {
                threads[threadID] = OsmoThread(id: threadID, updatedAt: epoch, deviceSeq: 0,
                                               platform: platform, platformThreadID: m.threadId,
                                               title: subject, isGroup: false, lastMessageAt: sentAt)
            }

            // The person the thread is with = the other party.
            let otherRaw = isFromMe ? (m.header("To") ?? "") : fromRaw
            var senderContactID: UUID?
            if let otherEmail = EmailAddress.extract(otherRaw) {
                let cid = OsmoContact.makeID(platform: platform, handle: otherEmail)
                if contacts[cid] == nil {
                    contacts[cid] = OsmoContact(id: cid, updatedAt: epoch, deviceSeq: 0,
                                                platform: platform, handle: otherEmail,
                                                displayName: EmailAddress.displayName(otherRaw), isMe: false)
                }
                if !isFromMe { senderContactID = cid }
            }

            let text = [subject, m.snippet].compactMap { $0 }.joined(separator: " — ")
            out.append(OsmoMessage(
                id: OsmoMessage.makeID(platform: platform, platformMessageID: m.id),
                updatedAt: epoch, deviceSeq: 0, platform: platform, platformMessageID: m.id,
                threadID: threadID, senderContactID: senderContactID, isFromMe: isFromMe,
                text: text, sentAt: sentAt))
        }

        return NormalizedBatch(contacts: Array(contacts.values),
                               threads: Array(threads.values), messages: out)
    }
}
