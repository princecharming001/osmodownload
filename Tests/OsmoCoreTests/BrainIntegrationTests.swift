import Testing
import Foundation
import GRDB
import RegisterKit
@testable import OsmoCore

/// The P0 gate capstone: proves the whole architecture loop is wired —
/// chat.db → normalizer → encrypted store → the **reused RegisterKit brain**
/// (CommunicationCraft psychology engine + PromptBuilder) produces a grounded
/// suggestion prompt from imported message data. This is the seam that makes
/// Osmo "port, not rebuild."
@Suite("Brain integration — imported data → RegisterKit engine (P0.5)")
struct BrainIntegrationTests {

    private func appleNanos(unix: TimeInterval) -> Int64 {
        Int64((unix - AppleTime.cocoaEpochOffset) * 1_000_000_000)
    }

    private func storeWithThread() throws -> OsmoStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osmo-brain-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try DatabaseQueue(path: url.path)
        try fixture.write { db in
            try db.execute(sql: "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
            try db.execute(sql: "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, style INTEGER)")
            try db.execute(sql: "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, handle_id INTEGER, is_from_me INTEGER, date INTEGER, date_read INTEGER)")
            try db.execute(sql: "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
            try db.execute(sql: "INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567')")
            try db.execute(sql: "INSERT INTO chat (ROWID, guid, chat_identifier, display_name, style) VALUES (1, 'iMessage;-;+15551234567', '+15551234567', NULL, 45)")
            try db.execute(sql: """
                INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, date_read)
                VALUES (1, 'G1', 'hey im so sorry i totally forgot to call you back last night', 1, 0, ?, 0)
                """, arguments: [appleNanos(unix: 1_800_000_000)])
            try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1)")
        }
        let store = try OsmoStore.inMemory()
        try IMessageImporter().importAll(from: url, into: store)
        return store
    }

    @Test("The reused CommunicationCraft engine reads an imported message")
    func craftReadsImportedMessage() throws {
        let store = try storeWithThread()
        let threadID = OsmoThread.makeID(platform: .imessage, platformThreadID: "+15551234567")
        let last = try store.messages(inThread: threadID).last!

        // The psychology engine — ported unchanged from RegisterKit — runs on the
        // imported text. The message is an apology; classify() should see that when
        // we frame it as the drafting intent.
        #expect(CommunicationCraft.classify("apologize for missing their call") == .apology)

        // Linguistic-Style-Matching read of THEIR actual imported message.
        let read = CommunicationCraft.read(last.text)
        #expect(read.wordCount > 8)
        #expect(read.mostlyLowercase)            // "hey im so sorry..." is lowercase
        #expect(!read.asksQuestion)
        let calibration = CommunicationCraft.calibrationLines(for: read)
        #expect(!calibration.isEmpty)
    }

    @Test("PromptBuilder produces a grounded reply prompt from imported context")
    func promptFromImportedContext() throws {
        let store = try storeWithThread()
        let threadID = OsmoThread.makeID(platform: .imessage, platformThreadID: "+15551234567")
        let last = try store.messages(inThread: threadID).last!

        // Build a reply request grounded in the imported message — exactly the
        // shape Osmo's overlay will send when you open this thread.
        let request = GenerationRequest(
            mode: .reply,
            baseVoice: "warm, concise, lowercase",
            personaVoice: "close friend, casual, we joke a lot",
            personaName: "Sam",
            relationship: "best friend",
            context: last.text,
            count: 3)
        let prompt = PromptBuilder().build(request)

        #expect(!prompt.isEmpty)
        #expect(prompt.contains(last.text))          // the imported message is in the prompt
        #expect(prompt.lowercased().contains("sam")) // persona wired through
        // The anti-AI-tell ruleset (RegisterKit) rides along.
        #expect(prompt.lowercased().contains("em-dash") || prompt.lowercased().contains("contraction"))
    }
}
