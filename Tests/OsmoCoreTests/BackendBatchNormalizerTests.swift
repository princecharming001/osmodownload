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
