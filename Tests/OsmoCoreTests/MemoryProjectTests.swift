import Testing
import Foundation
@testable import OsmoCore

@Suite("Relationship memory + Projects (O2)")
struct MemoryProjectTests {

    @Test("Memory persists, de-dupes facts, and renders a prompt block")
    func memory() throws {
        let store = try OsmoStore.inMemory()
        let person = UUID()
        var mem = RelationshipMemory(personID: person)
        mem.note = "she's been slammed at work"
        mem.addFact("her dog is Biscuit", kind: .fact)
        mem.addFact("never bring up her ex", kind: .dontRule)
        mem.addFact("always ask about her sister", kind: .doRule)
        mem.addFact("her dog is Biscuit", kind: .fact)   // dup → collapses
        try store.put(mem)

        let loaded = try store.memory(forPerson: person)
        #expect(loaded.facts.count == 3)
        let ctx = loaded.promptContext
        #expect(ctx.contains("Lately: she's been slammed at work"))
        #expect(ctx.contains("Always: always ask about her sister"))
        #expect(ctx.contains("Never: never bring up her ex"))
        #expect(ctx.contains("Remember: her dog is Biscuit"))
    }

    @Test("Empty memory renders an empty prompt block")
    func emptyMemory() throws {
        let store = try OsmoStore.inMemory()
        let mem = try store.memory(forPerson: UUID())
        #expect(mem.isEmpty)
        #expect(mem.promptContext.isEmpty)
    }

    @Test("Projects persist per person, filter by status, and carry goal/tone/boundaries")
    func projects() throws {
        let store = try OsmoStore.inMemory()
        let sarah = UUID()
        let dad = UUID()
        try store.put(Project(personID: sarah, title: "Land the Acme deal",
                              goalText: "get them to sign by Q3",
                              toneHint: "confident, low-pressure",
                              boundaries: ["don't discount below 15%"],
                              milestones: [Milestone(text: "get a call booked")]))
        try store.put(Project(personID: dad, title: "Rebuild trust",
                              goalText: "repair after the argument",
                              status: .active))
        try store.put(Project(personID: sarah, title: "Old thing",
                              goalText: "done", status: .archived))

        #expect(try store.projects(forPerson: sarah).count == 2)
        #expect(try store.activeProjects().count == 2)   // archived excluded
        let deal = try store.projects(forPerson: sarah).first { $0.status == .active }
        #expect(deal?.boundaries == ["don't discount below 15%"])
        #expect(deal?.milestones.first?.text == "get a call booked")
    }

    @Test("A user edit always advances the sync clock (wins LWW, syncs out)")
    func editAdvancesClock() throws {
        let store = try OsmoStore.inMemory()
        let p = Project(personID: UUID(), title: "T", goalText: "g")
        try store.put(p)
        let v1 = try store.project(id: p.id)!
        var edited = v1
        edited.goalText = "g2"
        try store.put(edited)
        let v2 = try store.project(id: p.id)!
        #expect(v2.goalText == "g2")
        #expect(v2.deviceSeq > v1.deviceSeq)
        #expect(v2.updatedAt >= v1.updatedAt)
    }

    @Test("Soft-deleting a project removes it from queries")
    func softDeleteProject() throws {
        let store = try OsmoStore.inMemory()
        let p = Project(personID: UUID(), title: "T", goalText: "g")
        try store.put(p)
        #expect(try store.activeProjects().count == 1)
        try store.softDelete(Project.self, id: p.id)
        #expect(try store.activeProjects().isEmpty)
        #expect(try store.project(id: p.id)?.sync.isDeleted == true)
    }
}
