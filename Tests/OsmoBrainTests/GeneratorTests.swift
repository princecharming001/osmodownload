import Testing
import Foundation
import OsmoCore
@testable import OsmoBrain

@Suite("AI client: keyless mock, proxy shaping, router, service (O5)")
struct GeneratorTests {

    /// Records the purpose it was handed, to prove the router forwards it.
    final class PurposeSpy: Generator, @unchecked Sendable {
        var seenPurpose: String? = nil
        var purposeWasSet = false
        func generate(systemCore: String, userTurn: String, count: Int) async throws -> String { "x" }
        func generate(systemCore: String, userTurn: String, count: Int, purpose: String?) async throws -> String {
            seenPurpose = purpose; purposeWasSet = true; return "x"
        }
    }

    @Test("GeneratorRouter forwards `purpose` to the live generator (not dropped)")
    func routerForwardsPurpose() async throws {
        let spy = PurposeSpy()
        let router = GeneratorRouter(live: spy)
        _ = try await router.generate(systemCore: "c", userTurn: "u", count: 1, purpose: "decision")
        #expect(spy.purposeWasSet)
        #expect(spy.seenPurpose == "decision")
    }

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
            send: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 503,
                                                    httpVersion: nil, headerFields: nil)!) })
        await #expect(throws: GenerationError.http(503)) {
            _ = try await gen.generate(systemCore: "c", userTurn: "u", count: 3)
        }
    }

    // MARK: - Device-token wiring (the prod 401 fix)

    /// 200 response with a canned text body.
    private static func okResponse(_ req: URLRequest, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: ["text": "a\nb\nc"]),
         HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }

    @Test("tokenProvider supplies the Bearer token; 'local-dev' does not count as manual")
    func tokenProviderResolution() async throws {
        let captured = Captured()
        let gen = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!,
                          authToken: "local-dev"),
            send: { req in await captured.set(req); return Self.okResponse(req) },
            tokenProvider: { "device-tok-9" })
        _ = try await gen.generate(systemCore: "c", userTurn: "u", count: 3)
        let req = await captured.request!
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer device-tok-9")
    }

    @Test("A manual Settings token wins over the provider")
    func manualTokenWins() async throws {
        let captured = Captured()
        let gen = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!,
                          authToken: "sess-manual"),
            send: { req in await captured.set(req); return Self.okResponse(req) },
            tokenProvider: { "device-tok-9" })
        _ = try await gen.generate(systemCore: "c", userTurn: "u", count: 3)
        let req = await captured.request!
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sess-manual")
    }

    @Test("401 then 200: refreshCredentials is called once, retry carries the fresh token")
    func retryOnceOn401() async throws {
        let calls = Counter()
        let refreshes = Counter()
        let tokens = TokenLog()
        let gen = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!,
                          authToken: "local-dev"),
            send: { req in
                await tokens.append(req.value(forHTTPHeaderField: "Authorization") ?? "")
                if await calls.increment() == 1 {
                    return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401,
                                                    httpVersion: nil, headerFields: nil)!)
                }
                return Self.okResponse(req)
            },
            tokenProvider: { "tok-stale" },
            refreshCredentials: { await refreshes.increment(); return "tok-fresh" })
        let out = try await gen.generate(systemCore: "c", userTurn: "u", count: 3)
        #expect(out == "a\nb\nc")
        #expect(await refreshes.count == 1)
        #expect(await tokens.all == ["Bearer tok-stale", "Bearer tok-fresh"])
    }

    @Test("401 twice: throws .http(401), refresh called exactly once")
    func doubleUnauthorized() async throws {
        let refreshes = Counter()
        let gen = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!,
                          authToken: "local-dev"),
            send: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 401,
                                                    httpVersion: nil, headerFields: nil)!) },
            tokenProvider: { "tok-stale" },
            refreshCredentials: { await refreshes.increment(); return "tok-fresh" })
        await #expect(throws: GenerationError.http(401)) {
            _ = try await gen.generate(systemCore: "c", userTurn: "u", count: 3)
        }
        #expect(await refreshes.count == 1)
    }

    @Test("429 maps to quotaExceeded with the x-osmo-drafts-remaining header (default 0)")
    func quotaMapping() async throws {
        let withHeader = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test")!, authToken: "t"),
            send: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil,
                                                    headerFields: ["x-osmo-drafts-remaining": "2"])!) })
        await #expect(throws: GenerationError.quotaExceeded(remaining: 2)) {
            _ = try await withHeader.generate(systemCore: "c", userTurn: "u", count: 3)
        }
        let bare = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test")!, authToken: "t"),
            send: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 429,
                                                    httpVersion: nil, headerFields: nil)!) })
        await #expect(throws: GenerationError.quotaExceeded(remaining: 0)) {
            _ = try await bare.generate(systemCore: "c", userTurn: "u", count: 3)
        }
    }

    @Test("URLError from the transport becomes .network")
    func urlErrorMapsToNetwork() async throws {
        let gen = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test")!, authToken: "t"),
            send: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: GenerationError.network) {
            _ = try await gen.generate(systemCore: "c", userTurn: "u", count: 3)
        }
    }

    @Test("Router policy: drafts mock network failures; ask propagates them")
    func routerNetworkPolicy() async throws {
        struct Failing: Generator {
            func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
                throw GenerationError.network
            }
        }
        // Default (drafts): unreachable proxy → mock, the keyless promise.
        let drafts = GeneratorRouter(live: Failing())
        let out = try await drafts.generate(systemCore: "c", userTurn: "u", count: 3)
        #expect(out.contains("[mock]"))
        // Ask: the failure must surface, not become a plausible mock answer.
        let ask = GeneratorRouter(live: Failing(), mockOnNetworkError: false)
        await #expect(throws: GenerationError.network) {
            _ = try await ask.generate(systemCore: "c", userTurn: "u", count: 3)
        }
        // .notConfigured still mocks on BOTH policies (keyless demo answers).
        struct Unconfigured: Generator {
            func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
                throw GenerationError.notConfigured
            }
        }
        let askUnconfigured = GeneratorRouter(live: Unconfigured(), mockOnNetworkError: false)
        #expect(try await askUnconfigured.generate(systemCore: "c", userTurn: "u", count: 3).contains("[mock]"))
        // Other errors (e.g. quota) propagate on the default policy too.
        struct Quota: Generator {
            func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
                throw GenerationError.quotaExceeded(remaining: 0)
            }
        }
        await #expect(throws: GenerationError.quotaExceeded(remaining: 0)) {
            _ = try await GeneratorRouter(live: Quota()).generate(systemCore: "c", userTurn: "u", count: 3)
        }
    }

    @Test("RuntimeConfig.manualAuthToken: empty and 'local-dev' mean automatic")
    func manualAuthToken() {
        #expect(RuntimeConfig(authToken: "local-dev").manualAuthToken == nil)
        #expect(RuntimeConfig(authToken: "").manualAuthToken == nil)
        #expect(RuntimeConfig(authToken: " sess-x ").manualAuthToken == "sess-x")
    }
}

/// Sendable-safe counters/logs for the stubbed transports.
private actor Counter {
    var count = 0
    @discardableResult
    func increment() -> Int { count += 1; return count }
}

private actor TokenLog {
    var all: [String] = []
    func append(_ s: String) { all.append(s) }
}

/// Actor to capture the request from the stubbed transport (Sendable-safe).
private actor Captured {
    var request: URLRequest?
    func set(_ r: URLRequest) { request = r }
}
