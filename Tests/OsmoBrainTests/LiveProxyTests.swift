import Testing
import Foundation
import OsmoCore
@testable import OsmoBrain

/// Live end-to-end test of the app's exact suggestion path — RuntimeConfig →
/// ClaudeProxyGenerator → the running Osmo proxy → Anthropic → parse. Off by
/// default; runs only with `OSMO_LIVE=1` and the `web/` dev server up. Proves the
/// app talks to a real model, not the mock.
@Suite("Live proxy (opt-in)")
struct LiveProxyTests {

    @Test("The app's config path returns real, non-mock takes from the proxy",
          .enabled(if: ProcessInfo.processInfo.environment["OSMO_LIVE"] == "1"))
    func liveProxy() async throws {
        let cfg = RuntimeConfig(proxyURL: "http://localhost:3000/api/suggest",
                                authToken: "local-dev", model: "claude-sonnet-5")
        let service = cfg.makeService()
        let result = try await service.suggest(SuggestionContext(
            relationshipLabel: "my boss", platform: .slack,
            goalText: "look on top of it without overpromising",
            transcript: [ThreadTurn(fromMe: false, text: "can you get me the Q3 numbers before the board call tomorrow?")],
            userIntent: "reassure and give a realistic time"))

        #expect(result.set.takes.count == 3)
        let first = result.set.takes.first?.text ?? ""
        #expect(!first.contains("[mock]"))        // real model, not the fallback
        #expect(!first.isEmpty)
        // The engine chose the apt psychology and attached the rationale.
        #expect(result.set.takes.first?.whyItWorks != nil)
        print("LIVE TAKE 1:", first)
        print("LIVE TAKE 2:", result.set.takes.dropFirst().first?.text ?? "")
        print("LIVE TAKE 3:", result.set.takes.last?.text ?? "")
    }
}
