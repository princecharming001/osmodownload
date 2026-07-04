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

    @Test("String similarity ratio behaves")
    func similarity() {
        #expect(StringSimilarity.ratio("Sarah", "Sarah") == 1)
        #expect(StringSimilarity.ratio("Jonathan", "Jonathon") > 0.8)
        #expect(StringSimilarity.ratio("Sarah", "Michael") < 0.4)
    }
}
