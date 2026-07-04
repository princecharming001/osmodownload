import Testing
import Foundation
import OsmoCore
@testable import OsmoBrain

@Suite("AI client: keyless mock, proxy shaping, router, service (O5)")
struct GeneratorTests {

    @Test("MockGenerator is keyless and yields three parseable slants")
    func mock() async throws {
        let raw = try await MockGenerator().generate(
            systemCore: "core", userTurn: "THE MOVE (this message is an apology)\nThem: you never called",
            count: 3)
        let set = SuggestionSet.parse(raw, leadWhy: nil)
        #expect(set.takes.count == 3)
        #expect(Set(set.takes.map(\.text)).count == 3)   // distinct
    }

    @Test("SuggestionService runs end-to-end keyless (plan → mock → parse)")
    func serviceKeyless() async throws {
        let svc = SuggestionService()   // GeneratorRouter(live: nil) → mock
        let ctx = SuggestionContext(relationshipLabel: "girlfriend", platform: .imessage,
                                    transcript: [ThreadTurn(fromMe: false, text: "that really hurt")],
                                    userIntent: "apologize for bailing")
        let result = try await svc.suggest(ctx)
        #expect(result.set.takes.count == 3)
        #expect(result.plan.strategy.techniques.contains { $0.id == "own-it-apology" })
        #expect(result.set.takes[0].whyItWorks != nil)   // psychology rationale attached
    }

    @Test("Service refuses manipulation before ever calling the generator")
    func serviceRefuses() async throws {
        let svc = SuggestionService()
        let ctx = SuggestionContext(relationshipLabel: "crush", platform: .imessage,
                                    goalText: "guilt trip them into coming over")
        do {
            _ = try await svc.suggest(ctx)
            Issue.record("should have refused")
        } catch GenerationError.refusedBySafety { /* expected */ }
    }

    @Test("ClaudeProxyGenerator shapes the request correctly and needs auth")
    func proxyShaping() async throws {
        // Not ready without an auth token.
        let unconfigured = ClaudeProxyGenerator(config: .init(proxyURL: URL(string: "https://x.test")!))
        await #expect(throws: GenerationError.notConfigured) {
            _ = try await unconfigured.generate(systemCore: "c", userTurn: "u", count: 3)
        }

        // With auth + a stubbed transport: assert the posted body + auth header.
        let captured = Captured()
        let gen = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!,
                          authToken: "sess-123", model: "claude-sonnet-5"),
            send: { req in
                await captured.set(req)
                let body = try! JSONSerialization.data(withJSONObject: ["text": "a\nb\nc"])
                return (body, HTTPURLResponse(url: req.url!, statusCode: 200,
                                              httpVersion: nil, headerFields: nil)!)
            })
        let out = try await gen.generate(systemCore: "PSYCH-CORE", userTurn: "USER-TURN", count: 3)
        #expect(out == "a\nb\nc")
        let req = await captured.request!
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sess-123")
        let sent = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(sent["systemCore"] as? String == "PSYCH-CORE")
        #expect(sent["userTurn"] as? String == "USER-TURN")
        #expect(sent["model"] as? String == "claude-sonnet-5")
    }

    @Test("Router uses the live generator when ready, falls back to mock when not")
    func router() async throws {
        // Live but unconfigured → falls through to mock.
        let unconfiguredLive = ClaudeProxyGenerator(config: .init(proxyURL: URL(string: "https://x.test")!))
        let router = GeneratorRouter(live: unconfiguredLive)
        let out = try await router.generate(systemCore: "c", userTurn: "u", count: 3)
        #expect(out.contains("[mock]"))   // fell back
    }

    @Test("Proxy maps non-2xx to a typed error")
    func proxyHTTPError() async throws {
        let gen = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test")!, authToken: "t"),
            send: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 429,
                                                    httpVersion: nil, headerFields: nil)!) })
        await #expect(throws: GenerationError.http(429)) {
            _ = try await gen.generate(systemCore: "c", userTurn: "u", count: 3)
        }
    }
}

/// Actor to capture the request from the stubbed transport (Sendable-safe).
private actor Captured {
    var request: URLRequest?
    func set(_ r: URLRequest) { request = r }
}
