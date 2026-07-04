import Testing
import Foundation
import GRDB
@testable import OsmoCore

/// Proves the "encrypted on your Mac" guarantee is real, not aspirational: with a
/// passphrase, the database file on disk is opaque SQLCipher ciphertext — no SQLite
/// header, no message text recoverable by grepping the raw bytes — and it only
/// decrypts with the right key. Runs against a real temp file (not in-memory).
@Suite("At-rest encryption (SQLCipher)")
struct EncryptionTests {

    private func tempDBPath(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osmo-enc-\(ProcessInfo.processInfo.processIdentifier)-\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("osmo.sqlite")
    }

    private func thread() -> OsmoThread {
        OsmoThread(id: OsmoThread.makeID(platform: .imessage, platformThreadID: "chat-1"),
                   updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                   platform: .imessage, platformThreadID: "chat-1", title: nil, isGroup: false)
    }
    private func message(_ threadID: UUID, text: String) -> OsmoMessage {
        OsmoMessage(id: OsmoMessage.makeID(platform: .imessage, platformMessageID: "m1"),
                    updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                    platform: .imessage, platformMessageID: "m1", threadID: threadID,
                    isFromMe: false, text: text, sentAt: Date(timeIntervalSince1970: 1000), readAt: nil)
    }

    private let canary = "PLAINTEXT_CANARY_9c3f_are_you_free_friday"
    private let passphrase = "correct-horse-battery-staple"

    @Test("An encrypted DB file contains no SQLite header and no plaintext message bytes")
    func fileIsOpaqueCiphertext() throws {
        let url = tempDBPath(#function)
        try? FileManager.default.removeItem(at: url)

        // Write a message through the encrypted store, then fully close it.
        try {
            let store = try OsmoStore(url: url, passphrase: passphrase)
            let t = thread(); try store.ingest(t)
            try store.ingest(message(t.id, text: canary))
            #expect(try store.messageCount() == 1)   // sanity: it really wrote
        }()

        // Inspect the raw bytes on disk.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count > 0)
        // SQLCipher encrypts the whole file, including the 16-byte header. A plain
        // SQLite file starts with the ASCII "SQLite format 3\0".
        let sqliteMagic = Data("SQLite format 3\0".utf8)
        #expect(!bytes.starts(with: sqliteMagic), "file still has a plaintext SQLite header — not encrypted")
        // The message text must not be recoverable by scanning the raw file.
        let canaryBytes = Data(canary.utf8)
        #expect(bytes.range(of: canaryBytes) == nil, "message plaintext found on disk — not encrypted")

        try? FileManager.default.removeItem(at: url)
    }

    @Test("The right passphrase decrypts; the wrong one cannot read the data")
    func passphraseGatesAccess() throws {
        let url = tempDBPath(#function)
        try? FileManager.default.removeItem(at: url)

        try {
            let store = try OsmoStore(url: url, passphrase: passphrase)
            let t = thread(); try store.ingest(t)
            try store.ingest(message(t.id, text: canary))
        }()

        // Correct key → data is there. Scoped so the connection is released
        // (deinit closes it) before the next open, avoiding a self-inflicted lock.
        let (count, text): (Int, String?) = try {
            let ok = try OsmoStore(url: url, passphrase: passphrase)
            return (try ok.messageCount(), try ok.messages(inThread: thread().id).first?.text)
        }()
        #expect(count == 1)
        #expect(text == canary)

        // Wrong key → SQLCipher can't decrypt the pages, so opening/migrating throws
        // rather than leaking rows.
        #expect(throws: (any Error).self) {
            let bad = try OsmoStore(url: url, passphrase: "wrong-key")
            _ = try bad.messageCount()
        }

        try? FileManager.default.removeItem(at: url)
    }
}
