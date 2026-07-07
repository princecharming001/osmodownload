import Testing
import Foundation
@testable import OsmoCore

@Suite("Shell store — drafts, snooze, send queue, export/delete")
struct ShellStoreTests {

    private func seeded() throws -> (OsmoStore, UUID) {
        let store = try OsmoStore.inMemory()
        let thread = OsmoThread(
            id: OsmoThread.makeID(platform: .imessage, platformThreadID: "c1"),
            updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
            platform: .imessage, platformThreadID: "c1", title: nil, isGroup: false)
        try store.ingest(thread)
        let message = OsmoMessage(
            id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m1"),
            updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
            platform: .imessage, platformMessageID: "m1", threadID: thread.id,
            isFromMe: false, text: "hello world", sentAt: Date(timeIntervalSince1970: 500))
        try store.ingest(message)
        return (store, thread.id)
    }

    @Test("Drafts save, overwrite, and clear on empty")
    func drafts() throws {
        let (store, threadID) = try seeded()
        #expect(try store.draft(forThread: threadID) == nil)
        try store.saveDraft("half-written thought", forThread: threadID)
        #expect(try store.draft(forThread: threadID) == "half-written thought")
        try store.saveDraft("rewritten", forThread: threadID)
        #expect(try store.draft(forThread: threadID) == "rewritten")
        try store.saveDraft("   ", forThread: threadID)
        #expect(try store.draft(forThread: threadID) == nil)
    }

    @Test("Follow-up arms, survives silence, and auto-clears when they reply")
    func followups() throws {
        let (store, threadID) = try seeded()
        let armedAt = Date()
        try store.setFollowup(thread: threadID, due: armedAt.addingTimeInterval(-60), now: armedAt)

        // Still silent → the reminder is live (and due).
        var live = try store.activeFollowups()
        #expect(live.map(\.threadID) == [threadID])
        #expect(live[0].due <= Date())

        // An OLD inbound (before arming) must NOT clear it — the seeded message
        // predates the reminder.
        live = try store.activeFollowups()
        #expect(live.count == 1)

        // They reply AFTER arming → the nudge is moot; it clears itself.
        try store.ingest(OsmoMessage(
            id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m2"),
            updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
            platform: .imessage, platformMessageID: "m2", threadID: threadID,
            isFromMe: false, text: "hey sorry, yes!", sentAt: armedAt.addingTimeInterval(30)))
        #expect(try store.activeFollowups().isEmpty)
        #expect(try store.followup(forThread: threadID) == nil)

        // My own messages never clear a reminder. (Re-arm AFTER m2's timestamp so
        // the earlier reply doesn't count against the new reminder.)
        let rearmedAt = armedAt.addingTimeInterval(120)
        try store.setFollowup(thread: threadID, due: rearmedAt.addingTimeInterval(3600), now: rearmedAt)
        try store.ingest(OsmoMessage(
            id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m3"),
            updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
            platform: .imessage, platformMessageID: "m3", threadID: threadID,
            isFromMe: true, text: "bump", sentAt: rearmedAt.addingTimeInterval(60)))
        #expect(try store.activeFollowups().count == 1)
    }

    @Test("Snoozed threads hide until due; due snoozes surface once")
    func snoozes() throws {
        let (store, threadID) = try seeded()
        try store.snooze(thread: threadID, until: Date().addingTimeInterval(3600))
        #expect(try store.snoozedThreadIDs().contains(threadID))

        // Force it due.
        try store.snooze(thread: threadID, until: Date(timeIntervalSinceNow: -1))
        let due = try store.dueSnoozes()
        #expect(due.map(\.threadID) == [threadID])
        // Second read: already cleared.
        #expect(try store.dueSnoozes().isEmpty)
        #expect(try !store.snoozedThreadIDs().contains(threadID))
    }

    @Test("Send queue: enqueue, list FIFO, bump attempts, dequeue")
    func sendQueue() throws {
        let (store, _) = try seeded()
        try store.enqueueSend(QueuedSend(platform: .slack, platformThreadID: "ch1", text: "first"))
        try store.enqueueSend(QueuedSend(platform: .gmail, platformThreadID: "th2", text: "second"))
        var queued = try store.queuedSends()
        #expect(queued.map(\.text) == ["first", "second"])

        try store.bumpSendAttempt(id: queued[0].id!)
        queued = try store.queuedSends()
        #expect(queued[0].attempts == 1)

        try store.dequeueSend(id: queued[0].id!)
        #expect(try store.queuedSends().map(\.text) == ["second"])
    }

    @Test("Export contains the data and no key material; counts match")
    func export() throws {
        let (store, _) = try seeded()
        let data = try store.exportJSON()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((json["messages"] as! [Any]).count == 1)
        #expect((json["threads"] as! [Any]).count == 1)
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("hello world"))
        #expect(!text.lowercased().contains("passphrase"))
        #expect(!text.contains("deviceToken"))
    }

    @Test("deleteAllData empties every table but keeps the schema usable")
    func deleteAll() throws {
        let (store, threadID) = try seeded()
        try store.saveDraft("bye", forThread: threadID)
        try store.deleteAllData()
        #expect(try store.messageCount() == 0)
        #expect(try store.threadCount() == 0)
        #expect(try store.draft(forThread: threadID) == nil)
        // Store still works after the wipe.
        let thread = OsmoThread(
            id: OsmoThread.makeID(platform: .slack, platformThreadID: "new"),
            updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
            platform: .slack, platformThreadID: "new", title: nil, isGroup: false)
        try store.ingest(thread)
        #expect(try store.threadCount() == 1)
    }
}
