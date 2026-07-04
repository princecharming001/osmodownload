import Foundation

/// Config for the thin server proxy. **The Anthropic key never lives in the app**
/// (it's greppable even in a notarized binary) — the client posts the composed
/// prompt to the user's own Osmo proxy, which holds the key, marks the psychology
/// core as a prompt-cached system block, enforces per-user quota, and stores
/// nothing. `authToken` (the user's Osmo session) is injected last; until then the
/// app runs on `MockGenerator`.
public struct ClaudeProxyConfig: Sendable, Equatable {
    public var proxyURL: URL
    public var authToken: String?
    public var model: String

    public init(proxyURL: URL, authToken: String? = nil, model: String = "claude-sonnet-5") {
        self.proxyURL = proxyURL
        self.authToken = authToken
        self.model = model
    }

    public var isReady: Bool { !(authToken ?? "").isEmpty }
}

/// Calls the Osmo proxy. Transport is injectable so request-shaping is testable
/// without a network.
public struct ClaudeProxyGenerator: Generator {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let config: ClaudeProxyConfig
    let send: Send

    public init(config: ClaudeProxyConfig, send: Send? = nil) {
        self.config = config
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GenerationError.http(-1) }
            return (data, http)
        }
    }

    public func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
        guard config.isReady else { throw GenerationError.notConfigured }
        var request = URLRequest(url: config.proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.authToken!)", forHTTPHeaderField: "Authorization")
        // The proxy caches `systemCore` (marks it cache_control ephemeral) and
        // enforces the anti-manipulation policy server-side too.
        let body: [String: Any] = [
            "model": config.model,
            "systemCore": systemCore,
            "userTurn": userTurn,
            "count": count
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else { throw GenerationError.http(http.statusCode) }
        let decoded = try JSONDecoder().decode(ProxyResponse.self, from: data)
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationError.empty
        }
        return decoded.text
    }

    struct ProxyResponse: Decodable { let text: String }
}

/// Chooses the live generator when configured, else the keyless mock — so the app
/// is always functional and silently upgrades when credentials arrive.
public struct GeneratorRouter: Generator {
    let live: Generator?
    let mock: Generator

    public init(live: Generator?, mock: Generator = MockGenerator()) {
        self.live = live
        self.mock = mock
    }

    public func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
        if let live {
            do { return try await live.generate(systemCore: systemCore, userTurn: userTurn, count: count) }
            catch GenerationError.notConfigured { /* not set up → mock */ }
            catch is URLError { /* proxy unreachable (e.g. dev server down) → mock */ }
        }
        return try await mock.generate(systemCore: systemCore, userTurn: userTurn, count: count)
    }
}

/// The app's runtime configuration — where the AI proxy lives + which model. Read
/// from disk (see the app's config loader); defaults point at a local dev proxy
/// so `npm run dev` in `web/` makes the app fully live. When the proxy is
/// unreachable or unset, the router falls back to the keyless mock.
public struct RuntimeConfig: Codable, Sendable, Equatable {
    public var proxyURL: String
    public var authToken: String
    public var model: String

    public init(proxyURL: String = "http://localhost:3000/api/suggest",
                authToken: String = "local-dev",
                model: String = "claude-sonnet-5") {
        self.proxyURL = proxyURL
        self.authToken = authToken
        self.model = model
    }

    public var liveGenerator: Generator? {
        guard let url = URL(string: proxyURL), !authToken.isEmpty else { return nil }
        return ClaudeProxyGenerator(config: .init(proxyURL: url, authToken: authToken, model: model))
    }

    public func makeService() -> SuggestionService {
        SuggestionService(generator: GeneratorRouter(live: liveGenerator))
    }
}
