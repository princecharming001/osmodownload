import Testing
import Foundation
@testable import OsmoCore

@Suite("Person enrichment — v9 table + accessors")
struct EnrichmentStoreTests {

    private func seededStore() throws -> (OsmoStore, Person) {
        let store = try OsmoStore.inMemory()
        let person = Person(displayName: "Maya Render")
        try store.dbQueue.write { db in try person.save(db) }
        return (store, person)
    }

    private func sample(_ personID: UUID) -> PersonEnrichment {
        PersonEnrichment(
            personID: personID,
            headline: "Head of Growth at Reelio",
            company: "Reelio", title: "Head of Growth",
            location: "San Francisco, CA",
            summary: "Ships fast, measures everything.",
            linkedinURL: "https://www.linkedin.com/in/maya",
            positions: [EnrichedPosition(title: "Head of Growth", company: "Reelio", period: "2023–present")],
            education: [EnrichedEducation(school: "UC Berkeley", degree: "BA", period: "2014–2018")],
            webFacts: [WebFact(text: "Maya spoke on a growth panel.", url: "https://ex.example/p")],
            source: .both)
    }

    @Test("Upsert → fetch roundtrips nested JSON arrays intact")
    func roundtrip() throws {
        let (store, person) = try seededStore()
        let original = sample(person.id)
        try store.upsertEnrichment(original)

        let fetched = try store.enrichment(forPerson: person.id)
        #expect(fetched?.headline == "Head of Growth at Reelio")
        #expect(fetched?.positions == original.positions)
        #expect(fetched?.education == original.education)
        #expect(fetched?.webFacts == original.webFacts)
        #expect(fetched?.source == .both)
        #expect(try store.enrichments().count == 1)
    }

    @Test("Second upsert overwrites — one row per person")
    func overwrite() throws {
        let (store, person) = try seededStore()
        try store.upsertEnrichment(sample(person.id))
        var updated = sample(person.id)
        updated.headline = "Founder at Northbeam"
        updated.source = .linkedin
        try store.upsertEnrichment(updated)

        #expect(try store.enrichments().count == 1)
        #expect(try store.enrichment(forPerson: person.id)?.headline == "Founder at Northbeam")
    }

    @Test("Deleting the person cascades the enrichment away")
    func cascade() throws {
        let (store, person) = try seededStore()
        try store.upsertEnrichment(sample(person.id))
        _ = try store.dbQueue.write { db in try Person.deleteOne(db, key: person.id) }
        #expect(try store.enrichment(forPerson: person.id) == nil)
    }

    @Test("deleteAllEnrichments + deleteAllData both clear the table")
    func deletion() throws {
        let (store, person) = try seededStore()
        try store.upsertEnrichment(sample(person.id))
        try store.deleteAllEnrichments()
        #expect(try store.enrichments().isEmpty)

        try store.upsertEnrichment(sample(person.id))
        try store.deleteAllData()
        #expect(try store.enrichments().isEmpty)
    }

    @Test("Export includes enrichments — the full-data promise stays honest")
    func export() throws {
        let (store, person) = try seededStore()
        try store.upsertEnrichment(sample(person.id))
        let json = String(decoding: try store.exportJSON(), as: UTF8.self)
        #expect(json.contains("enrichments"))
        #expect(json.contains("Head of Growth at Reelio"))
    }

    @Test("Staleness flips after 7 days")
    func staleness() throws {
        var fresh = sample(UUID())
        fresh.fetchedAt = Date()
        #expect(!fresh.isStale)
        fresh.fetchedAt = Date().addingTimeInterval(-8 * 86_400)
        #expect(fresh.isStale)
    }
}
