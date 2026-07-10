import Testing
import Foundation
import OsmoCore
@testable import OsmoBrain

/// Hostile-response and policy-matrix edges for the proxy generator + router:
/// bodies that aren't the contract (missing `text`, empty, huge, non-UTF-8),
/// a refresh hook that can't actually mint a fresh credential, and the full
/// GenerationError x fallback-policy grid.
@Suite("Generator edges — malformed proxy responses + router policy matrix")
struct GeneratorEdgeTests {

    private func gen(_ send: @escaping ClaudeProxyGenerator.Send,
                     refresh: ClaudeProxyGenerator.TokenProvider? = nil) -> ClaudeProxyGenerator {
        ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!, authToken: "t"),
            send: send, refreshCredentials: refresh)
    }

    private static func ok(_ req: URLRequest, _ body: Data) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: - Malformed 2xx bodies

    @Test("2xx with JSON missing `text` fails typed (.empty), not with a raw DecodingError")
    func missingTextKey() async {
        let g = gen { req in Self.ok(req, Data(#"{"message":"wrong shape"}"#.utf8)) }
        await #expect(throws: GenerationError.empty) {
            _ = try await g.generate(systemCore: "c", userTurn: "u", count: 3)
        }
    }

    @Test("2xx with empty / whitespace-only text is .empty")
    func emptyText() async {
        for body in [#"{"text":""}"#, #"{"text":"  \n  "}"#] {
            let g = gen { req in Self.ok(req, Data(body.utf8)) }
            await #expect(throws: GenerationError.empty) {
                _ = try await g.generate(systemCore: "c", userTurn: "u", count: 3)
            }
        }
    }

    @Test("2xx with a 1MB text passes through intact")
    func hugeText() async throws {
        let huge = String(repeating: "a", count: 1_000_000)
        let body = try JSONSerialization.data(withJSONObject: ["text": huge])
        let g = gen { req in Self.ok(req, body) }
        let out = try await g.generate(systemCore: "c", userTurn: "u", count: 3)
        #expect(out.count == 1_000_000)
    }

    @Test("2xx with non-UTF8 / non-JSON bytes is .empty, not a crash")
    func garbageBytes() async {
        let garbage = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x80, 0x81])
        let g = gen { req in Self.ok(req, garbage) }
        await #expect(throws: GenerationError.empty) {
            _ = try await g.generate(systemCore: "c", userTurn: "u", count: 3)
        }
    }

    // MARK: - 401 retry with a refresh that can't help

    @Test("401 where refresh returns the SAME stale token: exactly one retry, then a clean .http(401)")
    func refreshReturnsStaleToken() async {
        let sends = Counter()
        let refreshes = Counter()
        let g = ClaudeProxyGenerator(
            config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!,
                          authToken: "local-dev"),
            send: { req in
                await sends.increment()
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401,
                                                httpVersion: nil, headerFields: nil)!)
            },
            tokenProvider: { "tok-stale" },
            refreshCredentials: { await refreshes.increment(); return "tok-stale" })   // same token back
        await #expect(throws: GenerationError.http(401)) {
            _ = try await g.generate(systemCore: "c", userTurn: "u", count: 3)
        }
        #expect(await sends.count == 2, "one retry, never a loop")
        #expect(await refreshes.count == 1)
    }

    @Test("401 where refresh returns nil/empty: fails immediately after the first response")
    func refreshReturnsNothing() async {
        let sends = Counter()
        for bad in [nil, ""] as [String?] {
            await sends.reset()
            let g = ClaudeProxyGenerator(
                config: .init(proxyURL: URL(string: "https://api.osmo.test/suggest")!,
                              authToken: "local-dev"),
                send: { req in
                    await sends.increment()
                    return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401,
                                                    httpVersion: nil, headerFields: nil)!)
                },
                tokenProvider: { "tok" },
                refreshCredentials: { bad })
            await #expect(throws: GenerationError.http(401)) {
                _ = try await g.generate(systemCore: "c", userTurn: "u", count: 3)
            }
            #expect(await sends.count == 1, "no retry without a usable fresh token")
        }
    }

    // MARK: - Router policy matrix

    /// Every GenerationError case x both mockOnNetworkError policies. `nil`
    /// expected error = the router swallows it and answers with the mock.
    @Test("GeneratorRouter policy matrix: every error case x both fallback policies")
    func routerPolicyMatrix() async throws {
        struct Throwing: Generator {
            let error: any Error
            func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
                throw error
            }
        }
        let grid: [(label: String, error: any Error, mocksWhenTrue: Bool, mocksWhenFalse: Bool)] = [
            ("notConfigured", GenerationError.notConfigured, true, true),
            ("network", GenerationError.network, true, false),
            ("raw URLError", URLError(.cannotConnectToHost), true, false),
            ("http 500", GenerationError.http(500), false, false),
            ("http 401", GenerationError.http(401), false, false),
            ("empty", GenerationError.empty, false, false),
            ("refusedBySafety", GenerationError.refusedBySafety("no"), false, false),
            ("quotaExceeded", GenerationError.quotaExceeded(remaining: 1), false, false),
        ]
        for row in grid {
            for policy in [true, false] {
                let router = GeneratorRouter(live: Throwing(error: row.error),
                                             mockOnNetworkError: policy)
                let shouldMock = policy ? row.mocksWhenTrue : row.mocksWhenFalse
                if shouldMock {
                    let out = try await router.generate(systemCore: "c", userTurn: "u", count: 3)
                    #expect(out.contains("[mock]"), "\(row.label) policy=\(policy) should mock")
                } else {
                    do {
                        _ = try await router.generate(systemCore: "c", userTurn: "u", count: 3)
                        Issue.record("\(row.label) policy=\(policy) should propagate")
                    } catch {
                        // Propagated — and unchanged for the typed cases.
                        if let expected = row.error as? GenerationError {
                            #expect(error as? GenerationError == expected,
                                    "\(row.label) policy=\(policy) must propagate the ORIGINAL error")
                        }
                    }
                }
            }
        }
    }

    @Test("router with no live generator always answers (the keyless promise)")
    func noLiveAlwaysAnswers() async throws {
        for policy in [true, false] {
            let out = try await GeneratorRouter(live: nil, mockOnNetworkError: policy)
                .generate(systemCore: "c", userTurn: "u", count: 3)
            #expect(out.contains("[mock]"))
        }
    }
}

private actor Counter {
    var count = 0
    @discardableResult
    func increment() -> Int { count += 1; return count }
    func reset() { count = 0 }
}
