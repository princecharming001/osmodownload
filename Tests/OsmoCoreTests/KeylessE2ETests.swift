import Testing
import Foundation
@testable import OsmoCore

/// The full keyless loop against a REAL local backend — register → mock-connect
/// LinkedIn → backfill into a real store → dev-emit inbound → SSE doorbell →
/// row appears + inbound yields → send → outbox shows the exact text.
///
/// Off by default; needs `npm run dev` in web/ and `OSMO_E2E=1`. Zero credentials.
@Suite("Keyless E2E loop (opt-in)")
struct KeylessE2ETests {

    static var enabled: Bool { ProcessInfo.processInfo.environment["OSMO_E2E"] == "1" }
    static let base = URL(string: ProcessInfo.processInfo.environment["OSMO_E2E_URL"] ?? "http://localhost:3000")!

    @Test("register → connect → backfill → realtime inbound → send → outbox",
          .enabled(if: KeylessE2ETests.enabled))
    func fullLoop() async throws {
        let store = try OsmoStore.inMemory()
        let tokens = MemoryDeviceToken()
        let client = BackendClient(baseURL: Self.base, tokenStore: tokens)

        // 1. Register.
        let creds = try await client.registerIfNeeded()
        #expect(creds.mode == "mock")

        // 2. Connect mock LinkedIn: mint the link, then do what the wizard's
        //    Authorize button does (the UI path POSTs the same endpoint).
        let link = try await client.createConnectLink(platform: .linkedin)
        #expect(link.mode == "mock")
        var complete = URLRequest(url: Self.base.appendingPathComponent("api/connect/mock/complete"))
        complete.httpMethod = "POST"
        complete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        complete.httpBody = try JSONSerialization.data(withJSONObject: ["linkId": link.linkId])
        let (_, completeRes) = try await URLSession.shared.data(for: complete)
        #expect((completeRes as? HTTPURLResponse)?.statusCode == 200)

        // 3. Engine start → backfill lands.
        let engine = RealtimeSyncEngine(store: store, client: client,
                                        cursorStore: MemoryCursorStore(),
                                        iMessageDBPath: URL(fileURLWithPath: "/nonexistent"),
                                        reconcileInterval: .seconds(300),
                                        localPollInterval: .seconds(300))
        await engine.start()
        defer { Task { await engine.stop() } }

        try await eventually(within: 10) { try store.messageCount() >= 5 }
        let backfilled = try store.messageCount()
        #expect(try store.threadCount() >= 2)
        #expect(try !store.search("local-first").isEmpty || !store.search("platform team").isEmpty)

        // 4. Realtime: dev-emit an inbound; the SSE doorbell must deliver it
        //    without any manual pull.
        let inboundTask = Task { () -> String? in
            for await inbound in engine.inbound where !inbound.message.isFromMe {
                if inbound.message.text.contains("e2e-realtime") { return inbound.message.text }
            }
            return nil
        }
        var emit = URLRequest(url: Self.base.appendingPathComponent("api/dev/emit"))
        emit.httpMethod = "POST"
        emit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        emit.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
        emit.httpBody = try JSONSerialization.data(withJSONObject: [
            "platform": "linkedin", "text": "e2e-realtime ping \(UUID().uuidString.prefix(6))",
        ])
        let (_, emitRes) = try await URLSession.shared.data(for: emit)
        #expect((emitRes as? HTTPURLResponse)?.statusCode == 200)

        let received = await withTimeout(seconds: 15) { await inboundTask.value }
        #expect(received != nil, "SSE doorbell should deliver the emitted inbound within 15s")
        inboundTask.cancel()
        #expect(try store.messageCount() == backfilled + 1)

        // 5. Send an (edited) reply → echo ingests → outbox records exact text.
        let sentText = "e2e edited reply \(UUID().uuidString.prefix(6))"
        let echo = try await client.send(platform: .linkedin,
                                         platformThreadID: "demo-li-chat-1", text: sentText,
                                         idempotencyKey: UUID().uuidString)
        #expect(echo.isFromMe)
        let normalized = BackendBatchNormalizer.normalize(
            WireBatch(contacts: [], threads: [], messages: [echo], cursor: "", hasMore: false))
        for message in normalized.batch.messages { _ = try store.ingest(message) }

        var outboxReq = URLRequest(url: Self.base.appendingPathComponent("api/dev/outbox"))
        outboxReq.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
        let (outboxData, _) = try await URLSession.shared.data(for: outboxReq)
        let outbox = try JSONSerialization.jsonObject(with: outboxData) as! [String: [[String: Any]]]
        #expect(outbox["outbox"]!.contains { ($0["text"] as? String) == sentText })
    }

    // MARK: - Async helpers

    private func eventually(within seconds: Double, _ check: @escaping () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? check()) == true { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect((try? check()) == true, "condition not met within \(seconds)s")
    }

    private func withTimeout<T: Sendable>(seconds: Double,
                                          _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
