import Testing
import Foundation
@testable import OsmoCore

@Suite("Backend batch normalizer — deterministic IDs")
struct BackendBatchNormalizerTests {

    private func wireBatch() -> WireBatch {
        WireBatch(
            contacts: [WireContact(platform: "linkedin", handle: "urn:li:member:5",
                                   displayName: "Ada", isMe: false)],
            threads: [WireThread(platform: "linkedin", platformThreadID: "chat-9",
                                 title: "Ada", isGroup: false,
                                 lastMessageAt: Date(timeIntervalSince1970: 1000))],
            messages: [WireMessage(platform: "linkedin", platformMessageID: "m-1",
                                   platformThreadID: "chat-9", senderHandle: "urn:li:member:5",
                                   isFromMe: false, text: "hello",
                                   sentAt: Date(timeIntervalSince1970: 1000), readAt: nil)],
            cursor: "3", hasMore: false)
    }

    @Test("Minted UUIDs match the canonical makeID derivations exactly")
    func idsMatch() {
        let result = BackendBatchNormalizer.normalize(wireBatch())
        let batch = result.batch
        #expect(batch.contacts[0].id == OsmoContact.makeID(platform: .linkedin, handle: "urn:li:member:5"))
        #expect(batch.threads[0].id == OsmoThread.makeID(platform: .linkedin, platformThreadID: "chat-9"))
        #expect(batch.messages[0].id == OsmoMessage.makeID(platform: .linkedin, platformMessageID: "m-1"))
        // Message FKs resolve to the same derived IDs.
        #expect(batch.messages[0].threadID == batch.threads[0].id)
        #expect(batch.messages[0].senderContactID == batch.contacts[0].id)
        #expect(result.skippedUnknownPlatform == 0)
    }

    @Test("Unknown platforms are skipped, never fatal (forward compat)")
    func unknownPlatformSkips() {
        var wire = wireBatch()
        wire.contacts.append(WireContact(platform: "telegram", handle: "t-1", displayName: nil, isMe: false))
        wire.messages.append(WireMessage(platform: "telegram", platformMessageID: "tm-1",
                                         platformThreadID: "tc-1", senderHandle: nil,
                                         isFromMe: false, text: "hi",
                                         sentAt: Date(), readAt: nil))
        let result = BackendBatchNormalizer.normalize(wire)
        #expect(result.skippedUnknownPlatform == 2)
        #expect(result.batch.contacts.count == 1)
        #expect(result.batch.messages.count == 1)
    }

    @Test("Normalize → ingest → re-ingest is a dedup no-op")
    func ingestRoundTrip() throws {
        let store = try OsmoStore.inMemory()
        let batch = BackendBatchNormalizer.normalize(wireBatch()).batch
        for c in batch.contacts { _ = try store.ingest(c) }
        for t in batch.threads { _ = try store.ingest(t) }
        for m in batch.messages { #expect(try store.ingest(m) == true) }
        #expect(try store.messageCount() == 1)
        // Same wire content again → all no-ops.
        let again = BackendBatchNormalizer.normalize(wireBatch()).batch
        for m in again.messages { #expect(try store.ingest(m) == false) }
        #expect(try store.messageCount() == 1)
    }

    @Test("Wire dates decode ISO-8601 with and without fractional seconds")
    func dateDecoding() throws {
        let json = #"{"contacts":[],"threads":[],"messages":[{"platform":"slack","platformMessageID":"s1","platformThreadID":"c1","senderHandle":null,"isFromMe":false,"text":"x","sentAt":"2026-07-04T09:45:39.943Z","readAt":"2026-07-04T09:45:40Z"}],"cursor":"1","hasMore":false}"#
        let batch = try JSONDecoder.osmoWire.decode(WireBatch.self, from: Data(json.utf8))
        #expect(batch.messages[0].sentAt.timeIntervalSince1970 > 0)
        #expect(batch.messages[0].readAt != nil)
    }
}

@Suite("Thread hints — automatedHint + providerThreadID (D1/D3)")
struct ThreadHintsTests {
    @Test("automatedHint and providerThreadID flow from wire through the normalizer")
    func normalizerMapsHints() {
        let wire = WireBatch(
            contacts: [],
            threads: [WireThread(platform: "gmail", platformThreadID: "t-1", title: "Newsletter",
                                 isGroup: false, lastMessageAt: Date(),
                                 automatedHint: true, providerThreadID: "t-1")],
            messages: [], cursor: "1", hasMore: false)
        let batch = BackendBatchNormalizer.normalize(wire).batch
        #expect(batch.threads[0].automatedHint == true)
        #expect(batch.threads[0].providerThreadID == "t-1")
    }

    @Test("Missing hint fields default to false/nil — old servers decode fine")
    func missingHintsDefault() {
        let wire = WireBatch(
            contacts: [],
            threads: [WireThread(platform: "gmail", platformThreadID: "t-2", title: nil,
                                 isGroup: false, lastMessageAt: nil)],
            messages: [], cursor: "1", hasMore: false)
        let batch = BackendBatchNormalizer.normalize(wire).batch
        #expect(batch.threads[0].automatedHint == false)
        #expect(batch.threads[0].providerThreadID == nil)
    }

    @Test("preservingEnrichment: incoming nil providerThreadID never clobbers a stored value")
    func providerThreadIDNeverRegresses() throws {
        let store = try OsmoStore.inMemory()
        let platform = Platform.linkedin
        let id = OsmoThread.makeID(platform: platform, platformThreadID: "chat-1")
        let resolved = OsmoThread(id: id, updatedAt: .distantPast, deviceSeq: 0,
                                  platform: platform, platformThreadID: "chat-1", title: "Ada",
                                  isGroup: false, lastMessageAt: Date(timeIntervalSince1970: 100),
                                  providerThreadID: "urn:li:real-thread")
        _ = try store.ingest(resolved)

        // A later webhook bundle has no chat index → providerThreadID nil.
        let bare = OsmoThread(id: id, updatedAt: .distantPast, deviceSeq: 0,
                              platform: platform, platformThreadID: "chat-1", title: "Ada",
                              isGroup: false, lastMessageAt: Date(timeIntervalSince1970: 200))
        _ = try store.ingest(bare)

        let fetched = try store.thread(id: id)
        #expect(fetched?.providerThreadID == "urn:li:real-thread")
        #expect(fetched?.lastMessageAt == Date(timeIntervalSince1970: 200))   // newer date still wins
    }

    @Test("preservingEnrichment: an out-of-order OLDER lastMessageAt never regresses the stored newer one")
    func lastMessageAtNeverRegresses() throws {
        let store = try OsmoStore.inMemory()
        let platform = Platform.whatsapp
        let id = OsmoThread.makeID(platform: platform, platformThreadID: "chat-2")
        let newer = OsmoThread(id: id, updatedAt: .distantPast, deviceSeq: 0,
                               platform: platform, platformThreadID: "chat-2", title: "Group",
                               isGroup: true, lastMessageAt: Date(timeIntervalSince1970: 500))
        _ = try store.ingest(newer)

        // A page arriving out of order (older message) must not regress the thread's date.
        let older = OsmoThread(id: id, updatedAt: .distantPast, deviceSeq: 0,
                               platform: platform, platformThreadID: "chat-2", title: "Group",
                               isGroup: true, lastMessageAt: Date(timeIntervalSince1970: 100))
        _ = try store.ingest(older)

        let fetched = try store.thread(id: id)
        #expect(fetched?.lastMessageAt == Date(timeIntervalSince1970: 500))
    }
}
