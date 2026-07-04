import Testing
import Foundation
import CryptoKit
@testable import OsmoCore

@Suite("E2EE sync engine (O6)")
struct SyncEngineTests {

    private func thread(_ pid: String) -> OsmoThread {
        OsmoThread(id: OsmoThread.makeID(platform: .imessage, platformThreadID: pid),
                   updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                   platform: .imessage, platformThreadID: pid)
    }
    private func message(_ threadID: UUID, _ pid: String, _ text: String) -> OsmoMessage {
        OsmoMessage(id: OsmoMessage.makeID(platform: .imessage, platformMessageID: pid),
                    updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                    platform: .imessage, platformMessageID: pid, threadID: threadID,
                    isFromMe: false, text: text, sentAt: Date(timeIntervalSince1970: 1000))
    }

    @Test("Two Macs converge through the encrypted blob store")
    func converge() async throws {
        let blob = InMemoryBlobStore()
        let crypto = CryptoBox(passphrase: "correct horse battery staple")

        let macA = try OsmoStore.inMemory()
        let macB = try OsmoStore.inMemory()
        let engineA = SyncEngine(store: macA, blobStore: blob, crypto: crypto)
        let engineB = SyncEngine(store: macB, blobStore: blob, crypto: crypto)

        // Mac A ingests a thread + messages and a project.
        let t = thread("c1")
        try macA.ingest(t)
        try macA.ingest(message(t.id, "m1", "are you free friday"))
        try macA.ingest(message(t.id, "m2", "lunch maybe"))
        try macA.put(Project(personID: UUID(), title: "Deal", goalText: "close it"))

        // A pushes, B pulls.
        #expect(try await engineA.push() >= 4)
        let applied = try await engineB.pull()
        #expect(applied >= 4)

        // B now has A's data, searchable.
        #expect(try macB.messageCount() == 2)
        #expect(try macB.threadCount() == 1)
        #expect(try macB.search("friday").count == 1)
        #expect(try macB.activeProjects().count == 1)
    }

    @Test("The blob store holds only opaque ciphertext (server can't read messages)")
    func opacity() async throws {
        let blob = InMemoryBlobStore()
        let crypto = CryptoBox(passphrase: "hunter2")
        let mac = try OsmoStore.inMemory()
        let engine = SyncEngine(store: mac, blobStore: blob, crypto: crypto)
        let t = thread("c1"); try mac.ingest(t)
        try mac.ingest(message(t.id, "m1", "SECRETPLAINTEXT_bring_the_ring"))
        try await engine.push()

        let raw = await blob.rawBytes()
        #expect(!raw.isEmpty)
        for blobData in raw {
            let asString = String(decoding: blobData, as: UTF8.self)
            #expect(!asString.contains("SECRETPLAINTEXT"))   // not readable
        }
        // Wrong passphrase cannot decrypt.
        let wrong = CryptoBox(passphrase: "wrong")
        #expect(throws: (any Error).self) { _ = try wrong.open(raw[0]) }
    }

    @Test("Last-writer-wins resolves a conflicting edit by updatedAt")
    func lww() async throws {
        let blob = InMemoryBlobStore()
        let crypto = CryptoBox(passphrase: "k")
        let macA = try OsmoStore.inMemory()
        let macB = try OsmoStore.inMemory()
        let eA = SyncEngine(store: macA, blobStore: blob, crypto: crypto)
        let eB = SyncEngine(store: macB, blobStore: blob, crypto: crypto)

        // Both start with the same project (A creates, B pulls).
        let p = Project(personID: UUID(), title: "T", goalText: "original")
        try macA.put(p)
        try await eA.push(); try await eB.pull()
        #expect(try macB.project(id: p.id)?.goalText == "original")

        // B edits later → B's version should win everywhere.
        var edit = try macB.project(id: p.id)!
        edit.goalText = "edited on B"
        try macB.put(edit)
        try await eB.push(); try await eA.pull()
        #expect(try macA.project(id: p.id)?.goalText == "edited on B")
    }

    @Test("A tombstone propagates (soft-delete syncs)")
    func tombstonePropagates() async throws {
        let blob = InMemoryBlobStore()
        let crypto = CryptoBox(passphrase: "k")
        let macA = try OsmoStore.inMemory()
        let macB = try OsmoStore.inMemory()
        let eA = SyncEngine(store: macA, blobStore: blob, crypto: crypto)
        let eB = SyncEngine(store: macB, blobStore: blob, crypto: crypto)

        let p = Project(personID: UUID(), title: "T", goalText: "g")
        try macA.put(p)
        try await eA.push(); try await eB.pull()
        #expect(try macB.activeProjects().count == 1)

        try macA.softDelete(Project.self, id: p.id)
        try await eA.push(); try await eB.pull()
        #expect(try macB.activeProjects().isEmpty)          // deletion synced
        #expect(try macB.project(id: p.id)?.sync.isDeleted == true)
    }
}
