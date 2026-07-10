import Testing
import Foundation
import GRDB
@testable import OsmoCore

@Suite("searchPeople — cross-platform person search")
struct SearchPeopleTests {
    private func seeded() throws -> OsmoStore {
        let store = try OsmoStore.inMemory()
        let ada = Person(displayName: "Ada Lovelace")
        let ben = Person(displayName: "Ben Carter")
        try store.dbQueue.write { db in
            try ada.save(db); try ben.save(db)
            try OsmoContact(id: OsmoContact.makeID(platform: .imessage, handle: "+14155551234"),
                            updatedAt: .distantPast, deviceSeq: 0, platform: .imessage,
                            handle: "+14155551234", displayName: "Ada L.", personID: ada.id, isMe: false).save(db)
            try OsmoContact(id: OsmoContact.makeID(platform: .linkedin, handle: "urn:li:member:9"),
                            updatedAt: .distantPast, deviceSeq: 0, platform: .linkedin,
                            handle: "urn:li:member:9", displayName: "Ada Lovelace", personID: ada.id, isMe: false).save(db)
            try OsmoContact(id: OsmoContact.makeID(platform: .gmail, handle: "ben@example.com"),
                            updatedAt: .distantPast, deviceSeq: 0, platform: .gmail,
                            handle: "ben@example.com", displayName: "Ben C.", personID: ben.id, isMe: false).save(db)
        }
        return store
    }

    @Test("Matches by person display name")
    func matchesPersonName() throws {
        let hits = try seeded().searchPeople("lovelace")
        #expect(hits.count == 1)
        #expect(hits[0].person.displayName == "Ada Lovelace")
    }

    @Test("Matches by contact display name")
    func matchesContactDisplayName() throws {
        let hits = try seeded().searchPeople("ben c")
        #expect(hits.count == 1)
        #expect(hits[0].person.displayName == "Ben Carter")
    }

    @Test("Matches by raw handle substring")
    func matchesRawHandle() throws {
        let hits = try seeded().searchPeople("example.com")
        #expect(hits.count == 1)
        #expect(hits[0].person.displayName == "Ben Carter")
    }

    @Test("Matches a phone number by digits regardless of formatting")
    func matchesPhoneDigits() throws {
        let hits = try seeded().searchPeople("4155551234")
        #expect(hits.count == 1)
        #expect(hits[0].person.displayName == "Ada Lovelace")
    }

    @Test("A person with multiple platform contacts appears ONCE, with both platforms listed")
    func dedupesByPersonAcrossPlatforms() throws {
        let hits = try seeded().searchPeople("ada")
        #expect(hits.count == 1)
        #expect(Set(hits[0].platforms) == [.imessage, .linkedin])
    }

    @Test("Empty query returns nothing; unmatched query returns nothing")
    func emptyOrUnmatchedQuery() throws {
        let store = try seeded()
        #expect(try store.searchPeople("").isEmpty)
        #expect(try store.searchPeople("nonexistent zzz").isEmpty)
    }

    @Test("limit caps the result count")
    func limitCaps() throws {
        let store = try OsmoStore.inMemory()
        try store.dbQueue.write { db in
            for i in 0..<10 {
                try Person(displayName: "Match Person \(i)").save(db)
            }
        }
        let hits = try store.searchPeople("match", limit: 3)
        #expect(hits.count == 3)
    }
}

@Suite("outboundMessages — the user's own sent messages")
struct OutboundMessagesTests {
    @Test("Returns only isFromMe messages, newest first, respecting the limit")
    func filtersAndOrders() throws {
        let store = try OsmoStore.inMemory()
        let threadID = OsmoThread.makeID(platform: .imessage, platformThreadID: "t1")
        try store.dbQueue.write { db in
            try OsmoThread(id: threadID, updatedAt: .distantPast, deviceSeq: 0,
                          platform: .imessage, platformThreadID: "t1").save(db)
            try OsmoMessage(id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m1"),
                           updatedAt: .distantPast, deviceSeq: 0, platform: .imessage,
                           platformMessageID: "m1", threadID: threadID, senderContactID: nil,
                           isFromMe: true, text: "hey", sentAt: Date(timeIntervalSince1970: 100), readAt: nil).save(db)
            try OsmoMessage(id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m2"),
                           updatedAt: .distantPast, deviceSeq: 0, platform: .imessage,
                           platformMessageID: "m2", threadID: threadID, senderContactID: nil,
                           isFromMe: false, text: "hi back", sentAt: Date(timeIntervalSince1970: 150), readAt: nil).save(db)
            try OsmoMessage(id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m3"),
                           updatedAt: .distantPast, deviceSeq: 0, platform: .imessage,
                           platformMessageID: "m3", threadID: threadID, senderContactID: nil,
                           isFromMe: true, text: "cool", sentAt: Date(timeIntervalSince1970: 200), readAt: nil).save(db)
        }
        let outbound = try store.outboundMessages()
        #expect(outbound.count == 2)
        #expect(outbound.allSatisfy { $0.isFromMe })
        #expect(outbound[0].platformMessageID == "m3")   // newest first
    }
}

@Suite("v10/v11 migrations — thread hints + autodraft flag")
struct ThreadHintsAndAutodraftMigrationTests {
    @Test("A fresh in-memory store has automatedHint/providerThreadID/isAuto columns with correct defaults")
    func columnsExistWithDefaults() throws {
        let store = try OsmoStore.inMemory()
        let threadID = OsmoThread.makeID(platform: .gmail, platformThreadID: "t1")
        try store.dbQueue.write { db in
            try OsmoThread(id: threadID, updatedAt: .distantPast, deviceSeq: 0,
                          platform: .gmail, platformThreadID: "t1").save(db)
        }
        let thread = try store.thread(id: threadID)
        #expect(thread?.automatedHint == false)
        #expect(thread?.providerThreadID == nil)

        try store.saveDraft("hello there", forThread: threadID, isAuto: true)
        let record = try store.draftRecord(forThread: threadID)
        #expect(record?.isAuto == true)
        #expect(record?.text == "hello there")
    }

    @Test("A user-path save (default isAuto: false) always clears the auto flag")
    func userSaveClearsAutoFlag() throws {
        let store = try OsmoStore.inMemory()
        let threadID = OsmoThread.makeID(platform: .imessage, platformThreadID: "t2")
        try store.dbQueue.write { db in
            try OsmoThread(id: threadID, updatedAt: .distantPast, deviceSeq: 0,
                          platform: .imessage, platformThreadID: "t2").save(db)
        }
        try store.saveDraft("an autodraft", forThread: threadID, isAuto: true)
        #expect(try store.draftRecord(forThread: threadID)?.isAuto == true)

        // The user edits — the default 2-arg call site, unchanged since before this feature.
        try store.saveDraft("actually let me rewrite this", forThread: threadID)
        #expect(try store.draftRecord(forThread: threadID)?.isAuto == false)
    }
}

@Suite("v13 migration — outbound-reciprocity indexes")
struct OutboundReciprocityIndexMigrationTests {
    private func indexNames(_ dbQueue: DatabaseQueue) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
    }

    @Test("A fresh store has both v13 indexes")
    func freshStoreHasIndexes() throws {
        let store = try OsmoStore.inMemory()
        let names = try indexNames(store.dbQueue)
        #expect(names.contains("idx_message_sender"))
        #expect(names.contains("idx_message_thread_fromme"))
    }

    @Test("An EXISTING pre-v13 store (with data) upgrades cleanly and gains the indexes")
    func existingStoreUpgrades() throws {
        // Build a database stopped at v12 with rows already in it …
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try OsmoDatabase.migrator.migrate(queue, upTo: "v12-message-attachment")
        #expect(!(try indexNames(queue).contains("idx_message_sender")))

        let threadID = OsmoThread.makeID(platform: .imessage, platformThreadID: "t1")
        try queue.write { db in
            try OsmoThread(id: threadID, updatedAt: .distantPast, deviceSeq: 0,
                          platform: .imessage, platformThreadID: "t1").save(db)
            try OsmoMessage(id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m1"),
                           updatedAt: .distantPast, deviceSeq: 0,
                           platform: .imessage, platformMessageID: "m1", threadID: threadID,
                           isFromMe: true, text: "hi", sentAt: Date()).save(db)
        }

        // … then a normal open (the full migrator) picks up v13 in place.
        try OsmoDatabase.migrator.migrate(queue)
        let names = try indexNames(queue)
        #expect(names.contains("idx_message_sender"))
        #expect(names.contains("idx_message_thread_fromme"))

        // The store still works over the upgraded database (data survived).
        let store = try OsmoStore(dbQueue: queue)
        #expect(try store.messageCount() == 1)
        #expect(try store.outboundCounterpartyHandles().isEmpty)   // no senders yet
    }
}
