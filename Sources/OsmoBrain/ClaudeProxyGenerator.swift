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
    /// Dynamic credential source — reads the CURRENT device token each call (no
    /// static copy that can go stale). Also the shape of the 401 refresh hook.
    public typealias TokenProvider = @Sendable () async -> String?

    let config: ClaudeProxyConfig
    let send: Send
    let tokenProvider: TokenProvider?
    let refreshCredentials: TokenProvider?

    public init(config: ClaudeProxyConfig, send: Send? = nil,
                tokenProvider: TokenProvider? = nil,
                refreshCredentials: TokenProvider? = nil) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.refreshCredentials = refreshCredentials
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GenerationError.http(-1) }
            return (data, http)
        }
    }

    /// Resolution order: a manual token from Settings wins (non-empty and not the
    /// `"local-dev"` sentinel); else the dynamic provider; else the legacy static
    /// `authToken` — which keeps the DEBUG localhost keyless flow working.
    private func resolveToken() async -> String? {
        let manual = (config.authToken ?? "").trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty && manual != "local-dev" { return manual }
        if let tokenProvider, let provided = await tokenProvider(), !provided.isEmpty {
            return provided
        }
        return manual.isEmpty ? nil : manual
    }

    public func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
        guard var token = await resolveToken() else { throw GenerationError.notConfigured }
        // The proxy caches `systemCore` (marks it cache_control ephemeral) and
        // enforces the anti-manipulation policy server-side too.
        let body: [String: Any] = [
            "model": config.model,
            "systemCore": systemCore,
            "userTurn": userTurn,
            "count": count
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        // 401 retry-once: the device token may be stale (backend restart / rotated
        // registration) — refresh the credential once and retry with the new one.
        for attempt in 0..<2 {
            var request = URLRequest(url: config.proxyURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData

            let data: Data
            let http: HTTPURLResponse
            do { (data, http) = try await send(request) }
            catch is URLError { throw GenerationError.network }

            if http.statusCode == 401, attempt == 0, let refreshCredentials {
                if let fresh = await refreshCredentials(), !fresh.isEmpty {
                    token = fresh
                    continue
                }
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 429 {
                    let remaining = http.value(forHTTPHeaderField: "x-osmo-drafts-remaining")
                        .flatMap(Int.init) ?? 0
                    throw GenerationError.quotaExceeded(remaining: remaining)
                }
                throw GenerationError.http(http.statusCode)
            }
            // A 2xx whose body isn't the expected JSON shape (missing `text`,
            // non-JSON/non-UTF-8 bytes) carries no usable text — map it to the
            // typed `.empty` instead of leaking a raw DecodingError to callers.
            guard let decoded = try? JSONDecoder().decode(ProxyResponse.self, from: data),
                  !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GenerationError.empty
            }
            return decoded.text
        }
        throw GenerationError.http(401)   // refreshed once, still rejected
    }

    struct ProxyResponse: Decodable { let text: String }
}

/// Chooses the live generator when configured, else the keyless mock — so the app
/// is always functional and silently upgrades when credentials arrive.
public struct GeneratorRouter: Generator {
    let live: Generator?
    let mock: Generator
    /// Explicit fallback policy: drafts keep the keyless promise (unreachable
    /// proxy → mock), while Ask must surface the failure instead of answering
    /// with plausible-looking mock text. `.notConfigured` always mocks.
    public var mockOnNetworkError: Bool

    public init(live: Generator?, mock: Generator = MockGenerator(),
                mockOnNetworkError: Bool = true) {
        self.live = live
        self.mock = mock
        self.mockOnNetworkError = mockOnNetworkError
    }

    public func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
        if let live {
            do { return try await live.generate(systemCore: systemCore, userTurn: userTurn, count: count) }
            catch GenerationError.notConfigured { /* not set up → mock */ }
            catch GenerationError.network where mockOnNetworkError { /* proxy unreachable → mock */ }
            catch is URLError where mockOnNetworkError { /* same, from a live gen that didn't map it */ }
        }
        return try await mock.generate(systemCore: systemCore, userTurn: userTurn, count: count)
    }
}

/// The app's runtime configuration — where the AI proxy lives + which model. Read
/// from disk (see the app's config loader); defaults point at a local dev proxy
/// so `npm run dev` in `web/` makes the app fully live. When the proxy is
/// unreachable or unset, the router falls back to the keyless mock.
/// The backend origin baked into the app. Debug builds point at the local dev
/// server (so `npm run dev` in `web/` works); SHIPPED (Release) builds point at
/// the hosted production backend — this is what stops a downloaded app from
/// talking to localhost. Override at runtime via Settings if needed.
public enum OsmoBackend {
    #if DEBUG
    public static let base = "http://localhost:3000"
    #else
    public static let base = "https://api.leftonread.in"
    #endif
    public static var defaultProxyURL: String { base + "/api/suggest" }
}

public struct RuntimeConfig: Codable, Sendable, Equatable {
    public var proxyURL: String
    public var authToken: String
    public var model: String
    /// The connections backend origin (device auth, sync, realtime). Optional so
    /// old persisted configs still decode; defaults to the local dev server.
    public var backendURL: String?

    /// Dynamic credential source — the app wires this to the CURRENT registered
    /// device token (Keychain-backed), so the proxy path authenticates with the
    /// real credential instead of the `"local-dev"` sentinel. A manual Settings
    /// token (non-empty, not `"local-dev"`) still wins. Runtime-only: never
    /// persisted, ignored by Equatable.
    public var tokenProvider: (@Sendable () async -> String?)?
    /// Called once on a 401 to mint a fresh registration; returns the new token
    /// (or nil if re-registration failed). Runtime-only, like `tokenProvider`.
    public var refreshCredentials: (@Sendable () async -> String?)?

    // The closures are runtime wiring, not configuration — keep them out of the
    // persisted shape (and out of equality, below).
    private enum CodingKeys: String, CodingKey {
        case proxyURL, authToken, model, backendURL
    }

    public static func == (lhs: RuntimeConfig, rhs: RuntimeConfig) -> Bool {
        lhs.proxyURL == rhs.proxyURL && lhs.authToken == rhs.authToken
            && lhs.model == rhs.model && lhs.backendURL == rhs.backendURL
    }

    public init(proxyURL: String = OsmoBackend.defaultProxyURL,
                authToken: String = "local-dev",
                model: String = "claude-sonnet-5",
                backendURL: String? = OsmoBackend.base) {
        self.proxyURL = proxyURL
        self.authToken = authToken
        self.model = model
        self.backendURL = backendURL
    }

    /// Resolved backend origin (falls back to the local dev server).
    public var backendOrigin: URL {
        URL(string: backendURL ?? OsmoBackend.base) ?? URL(string: OsmoBackend.base)!
    }

    /// The manual Settings override, when set. Empty and the legacy `"local-dev"`
    /// sentinel both mean "automatic — use the registered device token".
    public var manualAuthToken: String? {
        let t = authToken.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty || t == "local-dev") ? nil : t
    }

    public var liveGenerator: Generator? {
        guard let url = URL(string: proxyURL) else { return nil }
        // Nothing to authenticate with at all → stay on the mock.
        guard !authToken.isEmpty || tokenProvider != nil else { return nil }
        // A hand-entered token must never be silently swapped — drop the dynamic
        // closures when a manual token is in force.
        let manual = manualAuthToken != nil
        return ClaudeProxyGenerator(
            config: .init(proxyURL: url, authToken: authToken.isEmpty ? nil : authToken, model: model),
            tokenProvider: manual ? nil : tokenProvider,
            refreshCredentials: manual ? nil : refreshCredentials)
    }

    public func makeService() -> SuggestionService {
        SuggestionService(generator: GeneratorRouter(live: liveGenerator))
    }

    /// The Ask path's service: same live generator, but network failures PROPAGATE
    /// (no silent mock answer that would read as a hallucination). `.notConfigured`
    /// still routes to the mock so the keyless demo keeps answering.
    public func makeAskService() -> SuggestionService {
        SuggestionService(generator: GeneratorRouter(live: liveGenerator, mockOnNetworkError: false))
    }
}
