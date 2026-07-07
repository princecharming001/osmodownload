import Testing
import Foundation
@testable import OsmoCore

@Suite("Identity graph (O3)")
struct IdentityGraphTests {

    private func contact(_ platform: Platform, _ handle: String, name: String? = nil,
                         avatar: Data? = nil) -> OsmoContact {
        OsmoContact(id: OsmoContact.makeID(platform: platform, handle: handle),
                    updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                    platform: platform, handle: handle, displayName: name, avatarData: avatar)
    }

    @Test("Handle normalization: phone + email are global, usernames platform-scoped")
    func normalize() {
        #expect(HandleNormalizer.normalize("+1 (555) 123-4567").value == "5551234567")
        #expect(HandleNormalizer.normalize("5551234567").isGlobal)
        #expect(HandleNormalizer.normalize("Sarah@Example.com ").value == "sarah@example.com")
        let user = HandleNormalizer.normalize("sarahj")
        #expect(user.kind == .username)
        #expect(!user.isGlobal)
    }

    @Test("Same phone across iMessage + WhatsApp resolves to one person")
    func deterministicMerge() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.imessage, "+15551234567", name: "Sarah"))
        try store.ingest(contact(.whatsapp, "5551234567", name: "Sarah J"))
        try store.ingest(contact(.slack, "U999", name: "Someone Else"))

        try store.rebuildIdentityGraph()
        #expect(try store.people().count == 2)   // Sarah (2 handles) + Someone Else

        let imsg = try store.contacts().first { $0.platform == .imessage }!
        let wa = try store.contacts().first { $0.platform == .whatsapp }!
        #expect(imsg.personID != nil)
        #expect(imsg.personID == wa.personID)     // same person
        #expect(try store.contacts(forPerson: imsg.personID!).count == 2)
    }

    @Test("Re-ingesting a contact preserves its identity link (enrichment survives)")
    func reingestPreservesLink() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.imessage, "+15551234567", name: "Sarah"))
        try store.ingest(contact(.whatsapp, "5551234567", name: "Sarah"))
        try store.rebuildIdentityGraph()
        let pid = try store.contacts().first!.personID
        #expect(pid != nil)
        // The reader runs again (personID nil in its output) — link must survive.
        try store.ingest(contact(.imessage, "+15551234567", name: "Sarah"))
        #expect(try store.contacts().first { $0.platform == .imessage }!.personID == pid)
    }

    @Test("Distinct usernames on different platforms do NOT auto-merge")
    func usernamesDontCrossMerge() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.slack, "sarahj", name: "Sarah"))
        try store.ingest(contact(.instagram, "sarahj", name: "Sarah"))
        try store.rebuildIdentityGraph()
        // Two people deterministically (usernames are platform-scoped)…
        #expect(try store.people().count == 2)
    }

    @Test("Similar names across clusters produce a review suggestion, not an auto-merge")
    func probabilisticSuggestion() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.slack, "u1", name: "Jonathan Reyes"))
        try store.ingest(contact(.instagram, "u2", name: "Jonathan Reyes"))
        let suggestions = try store.rebuildIdentityGraph()
        #expect(try store.people().count == 2)          // NOT silently merged
        #expect(suggestions.contains { $0.confidence >= IdentityResolver.suggestThreshold })
    }

    @Test("Confirming a merge folds contacts onto one person and tombstones the other")
    func confirmMerge() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.slack, "u1", name: "Jonathan Reyes"))
        try store.ingest(contact(.instagram, "u2", name: "Jon Reyes"))
        try store.rebuildIdentityGraph()
        let people = try store.people().sorted { $0.displayName < $1.displayName }
        #expect(people.count == 2)
        let survivor = try store.mergePeople(people.map(\.id))
        #expect(survivor?.reviewed == true)
        #expect(try store.people().count == 1)          // one tombstoned
        #expect(try store.contacts(forPerson: survivor!.id).count == 2)
    }

    @Test("A confirmed merge is NOT re-suggested on the next rebuild (the bug)")
    func mergeStopsResuggesting() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.slack, "u1", name: "Jonathan Reyes"))
        try store.ingest(contact(.instagram, "u2", name: "Jonathan Reyes"))
        let first = try store.rebuildIdentityGraph()
        #expect(!first.isEmpty)                          // suggested once

        let people = try store.people()
        _ = try store.mergePeople(people.map(\.id))

        // The heart of the fix: rebuilding again must NOT re-propose the pair the
        // user already confirmed — both clusters now resolve to one person.
        let second = try store.rebuildIdentityGraph()
        #expect(second.isEmpty)
        #expect(try store.people().count == 1)           // still one person, stable
    }

    @Test("'Not the same' persists — a rejected pair never returns")
    func rejectedPairNeverReturns() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.slack, "u1", name: "Jonathan Reyes"))
        try store.ingest(contact(.instagram, "u2", name: "Jonathan Reyes"))
        let s = try store.rebuildIdentityGraph()
        let pair = try #require(s.first)

        try store.rejectMergePair(contactIDsA: pair.contactIDsA, contactIDsB: pair.contactIDsB)

        let after = try store.rebuildIdentityGraph()
        #expect(after.isEmpty)                            // gone for good
        #expect(try store.people().count == 2)            // and NOT merged
    }

    @Test("pairKey is stable + order-independent")
    func pairKeyStable() {
        let a = [UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                 UUID(uuidString: "00000000-0000-0000-0000-000000000009")!]
        let b = [UUID(uuidString: "00000000-0000-0000-0000-000000000005")!]
        #expect(IdentityResolver.pairKey(a, b) == IdentityResolver.pairKey(b, a))
        #expect(IdentityResolver.pairKey(a, b) ==
                "00000000-0000-0000-0000-000000000002|00000000-0000-0000-0000-000000000005")
    }

    @Test("A shared photo pairs two clusters even when names differ (avatar block)")
    func avatarMatchAcrossDifferentNames() throws {
        let store = try OsmoStore.inMemory()
        let photo = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try store.ingest(contact(.slack, "u1", name: "Bob", avatar: photo))
        try store.ingest(contact(.instagram, "u2", name: "Robert", avatar: photo))
        let suggestions = try store.rebuildIdentityGraph()
        #expect(try store.people().count == 2)                 // not auto-merged
        // "Bob"/"Robert" fall in different name buckets, but the identical photo
        // must still surface a high-confidence suggestion.
        #expect(suggestions.contains { $0.confidence >= 0.9 })
    }

    @Test("String similarity ratio behaves")
    func similarity() {
        #expect(StringSimilarity.ratio("Sarah", "Sarah") == 1)
        #expect(StringSimilarity.ratio("Jonathan", "Jonathon") > 0.8)
        #expect(StringSimilarity.ratio("Sarah", "Michael") < 0.4)
    }

    @Test("Two contacts that both inherited a group's title as their displayName are never suggested (the spam bug)")
    func groupTitleContactsNeverSuggested() throws {
        let store = try OsmoStore.inMemory()
        // Simulate the leaked-title bug: two different group-message senders
        // whose displayName ended up being the SAME group's title.
        try store.ingest(contact(.whatsapp, "att1", name: "General"))
        try store.ingest(contact(.instagram, "att2", name: "General"))
        try store.dbQueue.write { db in
            try OsmoThread(id: OsmoThread.makeID(platform: .whatsapp, platformThreadID: "grp1"),
                          updatedAt: .distantPast, deviceSeq: 0,
                          platform: .whatsapp, platformThreadID: "grp1",
                          title: "General", isGroup: true).save(db)
        }
        let suggestions = try store.rebuildIdentityGraph()
        #expect(suggestions.isEmpty)
        #expect(try store.people().count == 2)   // two distinct people, correctly NOT merged
    }

    @Test("The static generic-name stoplist blocks a match even with no group thread on record")
    func genericStoplistBlocksWithoutThread() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.slack, "u1", name: "Announcements"))
        try store.ingest(contact(.gmail, "u2", name: "announcements"))
        let suggestions = try store.rebuildIdentityGraph()
        #expect(suggestions.isEmpty)
    }

    @Test("A real person whose name happens to share letters with a group title still gets suggested")
    func realNamesStillWorkAlongsideExclusions() throws {
        let store = try OsmoStore.inMemory()
        try store.ingest(contact(.whatsapp, "att1", name: "General"))   // excluded
        try store.ingest(contact(.slack, "u1", name: "Jonathan Reyes"))
        try store.ingest(contact(.instagram, "u2", name: "Jonathan Reyes"))
        try store.dbQueue.write { db in
            try OsmoThread(id: OsmoThread.makeID(platform: .whatsapp, platformThreadID: "grp1"),
                          updatedAt: .distantPast, deviceSeq: 0,
                          platform: .whatsapp, platformThreadID: "grp1",
                          title: "General", isGroup: true).save(db)
        }
        let suggestions = try store.rebuildIdentityGraph()
        #expect(suggestions.contains { $0.displayNameA == "Jonathan Reyes" && $0.displayNameB == "Jonathan Reyes" })
        #expect(!suggestions.contains { $0.displayNameA == "General" || $0.displayNameB == "General" })
    }
}
