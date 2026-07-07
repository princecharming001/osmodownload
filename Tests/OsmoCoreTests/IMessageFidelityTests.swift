import Testing
import Foundation
@testable import OsmoCore

@Suite("iMessage fidelity — tapbacks, replies, group senders")
struct IMessageFidelityTests {

    private func raw(_ guid: String, _ text: String, from handle: String?, isFromMe: Bool = false,
                     chat: String = "+15550000000", style: Int = 45, chatName: String? = nil,
                     assocType: Int = 0, assocGuid: String? = nil, assocEmoji: String? = nil,
                     replyGuid: String? = nil) -> RawIMessage {
        RawIMessage(
            guid: guid, text: text, isFromMe: isFromMe, dateRaw: 0, dateReadRaw: 0,
            handle: handle, chatGUID: "iMessage;-;\(chat)", chatIdentifier: chat,
            chatDisplayName: chatName, chatStyle: style, rowID: 0,
            associatedType: assocType, associatedGuid: assocGuid,
            associatedEmoji: assocEmoji, threadOriginatorGuid: replyGuid)
    }

    @Test("A tapback folds onto its target as a reaction, not a message bubble")
    func tapbackFolds() {
        let batch = IMessageNormalizer.normalize([
            raw("BASE", "you free friday?", from: "+15551112222"),
            raw("RX1", "", from: "+15553334444", assocType: 2000, assocGuid: "p:0/BASE"),  // ❤️
        ])
        #expect(batch.messages.count == 1)                       // the tapback is NOT a message
        #expect(batch.reactionAdds.count == 1)
        let r = batch.reactionAdds[0]
        #expect(r.emoji == "❤️")
        #expect(r.reactionType == "heart")
        #expect(r.targetMessageID == OsmoMessage.makeID(platform: .imessage, platformMessageID: "BASE"))
        #expect(r.isFromMe == false)
    }

    @Test("A remove tapback (3000-series) deletes the matching add by id")
    func tapbackRemoveMatchesAdd() {
        let add = IMessageNormalizer.normalize([
            raw("RX1", "", from: "+15553334444", assocType: 2000, assocGuid: "p:0/BASE")]).reactionAdds[0]
        let remove = IMessageNormalizer.normalize([
            raw("RX2", "", from: "+15553334444", assocType: 3000, assocGuid: "p:0/BASE")]).reactionRemoves
        #expect(remove == [add.id])   // same (target, reactor, type) → same deterministic id
    }

    @Test("An arbitrary-emoji tapback uses associated_message_emoji")
    func customEmojiTapback() {
        let batch = IMessageNormalizer.normalize([
            raw("RX", "", from: "+15553334444", assocType: 2006, assocGuid: "bp:BASE", assocEmoji: "🔥")])
        #expect(batch.reactionAdds.first?.emoji == "🔥")
    }

    @Test("A reply links to its parent via inReplyToMessageID")
    func replyLinks() {
        let batch = IMessageNormalizer.normalize([
            raw("PARENT", "dinner at 7?", from: "+15551112222"),
            raw("CHILD", "works for me", from: "+15551112222", replyGuid: "PARENT"),
        ])
        let child = batch.messages.first { $0.platformMessageID == "CHILD" }!
        #expect(child.inReplyToMessageID == OsmoMessage.makeID(platform: .imessage, platformMessageID: "PARENT"))
        let parent = batch.messages.first { $0.platformMessageID == "PARENT" }!
        #expect(parent.inReplyToMessageID == nil)
    }

    @Test("A group thread keeps each sender distinct (who-said-what)")
    func groupSenders() {
        let batch = IMessageNormalizer.normalize([
            raw("M1", "bro shut up", from: "+15551112222", chat: "chat42", style: 43),
            raw("M2", "school starts in 2 months", from: "+15559998888", chat: "chat42", style: 43),
            raw("M3", "ig bro", from: nil, isFromMe: true, chat: "chat42", style: 43),
        ])
        #expect(batch.threads.count == 1)
        #expect(batch.threads[0].isGroup)
        #expect(batch.contacts.count == 2)                       // two distinct senders
        let m1 = batch.messages.first { $0.platformMessageID == "M1" }!
        let m2 = batch.messages.first { $0.platformMessageID == "M2" }!
        #expect(m1.senderContactID != nil)
        #expect(m2.senderContactID != nil)
        #expect(m1.senderContactID != m2.senderContactID)        // NOT collapsed to one person
        #expect(batch.messages.first { $0.platformMessageID == "M3" }!.senderContactID == nil)  // from me
    }

    @Test("Reactions round-trip through the store, grouped by target message")
    func storeRoundTrip() throws {
        let store = try OsmoStore.inMemory()
        let batch = IMessageNormalizer.normalize([
            raw("BASE", "gg", from: "+15551112222"),
            raw("RX1", "", from: "+15553334444", assocType: 2001, assocGuid: "p:0/BASE"),  // 👍
            raw("RX2", "", from: nil, isFromMe: true, assocType: 2000, assocGuid: "p:0/BASE"),  // ❤️ from me
        ])
        for c in batch.contacts { try store.ingest(c) }
        for t in batch.threads { try store.ingest(t) }
        for m in batch.messages { _ = try store.ingest(m) }
        for r in batch.reactionAdds { try store.upsertReaction(r) }

        let threadID = batch.threads[0].id
        let byTarget = try store.reactions(inThread: threadID)
        let targetID = OsmoMessage.makeID(platform: .imessage, platformMessageID: "BASE")
        #expect(byTarget[targetID]?.count == 2)                  // 👍 + ❤️
        #expect(Set(byTarget[targetID]!.map(\.emoji)) == ["👍", "❤️"])

        // A remove drops exactly the 👍 and leaves the ❤️.
        let removeID = MessageReaction.makeID(targetGuid: "BASE", reactorKey: "+15553334444", type: "like")
        try store.removeReaction(id: removeID)
        #expect(try store.reactions(inThread: threadID)[targetID]?.count == 1)
    }
}
