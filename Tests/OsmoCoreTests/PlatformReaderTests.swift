import Testing
import Foundation
import GRDB
@testable import OsmoCore

@Suite("Platform readers: Gmail, Slack, WhatsApp (O7)")
struct PlatformReaderTests {

    // MARK: Gmail

    @Test("Gmail messages normalize with direction + the other party as contact")
    func gmail() throws {
        let json = """
        [
          {"id":"g1","threadId":"t1","internalDate":"1800000000000","snippet":"can we move the call",
           "payload":{"headers":[{"name":"From","value":"Sarah Lee <sarah@acme.com>"},
                                 {"name":"To","value":"me@self.com"},
                                 {"name":"Subject","value":"Friday sync"}]}},
          {"id":"g2","threadId":"t1","internalDate":"1800000100000","snippet":"sure, 3pm works",
           "payload":{"headers":[{"name":"From","value":"me@self.com"},
                                 {"name":"To","value":"sarah@acme.com"},
                                 {"name":"Subject","value":"Re: Friday sync"}]}}
        ]
        """
        let msgs = try JSONDecoder().decode([GmailMessage].self, from: Data(json.utf8))
        let batch = GmailNormalizer.normalize(msgs, selfEmail: "me@self.com")

        let store = try OsmoStore.inMemory()
        batch.contacts.forEach { try? store.ingest($0) }
        batch.threads.forEach { try? store.ingest($0) }
        batch.messages.forEach { try? store.ingest($0) }

        #expect(try store.threadCount() == 1)
        #expect(try store.messageCount() == 2)
        #expect(try store.contacts().contains { $0.handle == "sarah@acme.com" && $0.displayName == "Sarah Lee" })
        let t = OsmoThread.makeID(platform: .gmail, platformThreadID: "t1")
        let ordered = try store.messages(inThread: t)
        #expect(ordered.first?.isFromMe == false)   // Sarah's message first
        #expect(ordered.last?.isFromMe == true)      // my reply
        #expect(try store.search("call").count == 1)
    }

    // MARK: Slack

    @Test("Slack conversation normalizes with self-direction + peer contact")
    func slack() throws {
        let convo = SlackConversation(
            id: "D123", name: "Jordan", isGroup: false, peerUserID: "UJORDAN",
            messages: [
                SlackMessage(ts: "1800000000.000100", user: "UJORDAN", text: "did you see the doc"),
                SlackMessage(ts: "1800000100.000200", user: "USELF", text: "yep looking now")
            ])
        let batch = SlackNormalizer.normalize([convo], selfUserID: "USELF")
        let store = try OsmoStore.inMemory()
        batch.contacts.forEach { try? store.ingest($0) }
        batch.threads.forEach { try? store.ingest($0) }
        batch.messages.forEach { try? store.ingest($0) }

        #expect(try store.messageCount() == 2)
        #expect(try store.contacts().contains { $0.handle == "UJORDAN" && $0.displayName == "Jordan" })
        let t = OsmoThread.makeID(platform: .slack, platformThreadID: "D123")
        let msgs = try store.messages(inThread: t)
        #expect(msgs.first { $0.text.contains("doc") }?.isFromMe == false)
        #expect(msgs.first { $0.text.contains("looking") }?.isFromMe == true)
    }

    // MARK: WhatsApp (local DB)

    @Test("WhatsApp local msgstore reads into the canonical schema")
    func whatsapp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wa-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try DatabaseQueue(path: url.path)
        try fixture.write { db in
            try db.execute(sql: """
                CREATE TABLE messages (_id INTEGER PRIMARY KEY, key_remote_jid TEXT,
                                       key_from_me INTEGER, data TEXT, timestamp INTEGER)
                """)
            try db.execute(sql: """
                INSERT INTO messages (_id, key_remote_jid, key_from_me, data, timestamp) VALUES
                  (1, '15551234567@s.whatsapp.net', 0, 'you around this weekend', 1800000000000),
                  (2, '15551234567@s.whatsapp.net', 1, 'yeah what''s up', 1800000100000),
                  (3, '99999@g.us', 0, 'group trip planning', 1800000200000)
                """)
        }
        let store = try OsmoStore.inMemory()
        let stats = try WhatsAppImporter().importAll(from: url, into: store)
        #expect(stats.threads == 2)          // 1:1 + group
        #expect(stats.messages == 3)
        #expect(stats.contacts == 1)         // one 1:1 peer (group senders id-only)

        let dm = OsmoThread.makeID(platform: .whatsapp, platformThreadID: "15551234567@s.whatsapp.net")
        let msgs = try store.messages(inThread: dm)
        #expect(msgs.count == 2)
        #expect(msgs.first?.isFromMe == false)
        #expect(try store.thread(id: OsmoThread.makeID(platform: .whatsapp, platformThreadID: "99999@g.us"))?.isGroup == true)
        #expect(try store.search("weekend").count == 1)
    }

    // MARK: API request shaping (creds-last)

    @Test("Gmail + Slack request builders carry auth + correct endpoints")
    func requestShaping() {
        let g = GmailAPI.messageGetRequest(token: "tok", id: "abc")
        #expect(g.url?.absoluteString.contains("messages/abc") == true)
        #expect(g.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let send = GmailAPI.sendRequest(token: "tok", rfc822Base64: "cmF3")
        #expect(send.httpMethod == "POST")
        #expect(send.url?.absoluteString.hasSuffix("messages/send") == true)

        let s = SlackAPI.conversationsHistoryRequest(token: "xoxp", channel: "D1")
        #expect(s.url?.absoluteString.contains("conversations.history") == true)
        #expect(s.url?.absoluteString.contains("channel=D1") == true)
        #expect(s.value(forHTTPHeaderField: "Authorization") == "Bearer xoxp")

        let creds = APICredentials()
        #expect(!creds.gmailReady && !creds.slackReady)   // keyless by default
    }
}
