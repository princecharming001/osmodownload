import Foundation

/// The Mac app's one HTTP surface: device auth, connect links, cursor pulls,
/// sends, and the SSE doorbell stream. Transports are injectable closures (the
/// repo's testing convention) — production uses URLSession.
///
/// Failure posture, by design:
/// - 401 anywhere → re-register once and retry once. A keyless dev backend
///   restart wipes its in-memory state; re-registration + a cursor reset makes
///   the app self-heal (re-pull is idempotent via deterministic IDs).
/// - SSE drops → exponential backoff 1s→60s (±20% jitter), reset on any
///   successfully parsed frame; a silent stream (no heartbeat > 60s) counts as
///   dead. Events are doorbells only — a missed one costs at most one
///   reconciliation interval, never data.
public actor BackendClient {
    public typealias DataTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias ByteStream = @Sendable (URLRequest) async throws -> AsyncThrowingStream<Data, Error>

    public enum BackendError: Error, Equatable {
        case badStatus(Int)
        case notRegistered
        case invalidResponse
    }

    private let baseURL: URL
    private let tokenStore: DeviceTokenStoring
    private let transport: DataTransport
    private let byteStream: ByteStream
    private var credentials: DeviceCredentials?

    /// Fires when a 401-triggered re-registration succeeds — the sync engine
    /// resets its cursor so the fresh backend state is fully re-pulled.
    public var onReRegistered: (@Sendable () -> Void)?
    public func setOnReRegistered(_ handler: @escaping @Sendable () -> Void) {
        onReRegistered = handler
    }

    public init(baseURL: URL,
                tokenStore: DeviceTokenStoring = KeychainDeviceToken(),
                transport: DataTransport? = nil,
                byteStream: ByteStream? = nil) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.transport = transport ?? Self.urlSessionTransport
        self.byteStream = byteStream ?? Self.urlSessionByteStream
    }

    // MARK: - Registration

    @discardableResult
    public func registerIfNeeded() async throws -> DeviceCredentials {
        if let creds = credentials { return creds }
        if let stored = try? tokenStore.load() {
            credentials = stored
            return stored
        }
        return try await register()
    }

    @discardableResult
    private func register() async throws -> DeviceCredentials {
        let creds = try await mintCredentials()
        commit(creds)
        return creds
    }

    /// POST /api/device/register and decode — NO stored-credential side effects,
    /// so a caller can mint a fresh identity first and only commit it on success
    /// (the refresh path must never be left credential-less by a failed mint).
    private func mintCredentials() async throws -> DeviceCredentials {
        let (data, response) = try await transport(request("POST", "/api/device/register"))
        guard response.statusCode == 200 else { throw BackendError.badStatus(response.statusCode) }
        return try JSONDecoder.osmoWire.decode(DeviceCredentials.self, from: data)
    }

    /// Atomically adopt a freshly minted identity (memory + Keychain).
    /// A fresh device identity means any prior sync cursor is meaningless —
    /// notify so the caller resets it (idempotent full re-pull). Firing this
    /// on every commit covers the SSE-reconnect, authed-401, AND refresh paths;
    /// the first-launch call is harmless (cursor is already empty).
    private func commit(_ creds: DeviceCredentials) {
        credentials = creds
        try? tokenStore.store(creds)
        onReRegistered?()
    }

    /// True once registered against a keyless backend (drives the demo banner).
    public func isMockMode() async -> Bool {
        // Mode is a property of the SERVER, not the stored credential — a
        // device registered once against a keyless dev server used to carry
        // mode:"mock" forever, keeping canned demo answers even against
        // production. Ask the backend; fall back to the stored flag offline.
        struct VersionInfo: Decodable { let mode: String? }
        if let (data, response) = try? await transport(request("GET", "/api/version")),
           response.statusCode == 200,
           let info = try? JSONDecoder.osmoWire.decode(VersionInfo.self, from: data),
           let mode = info.mode {
            return mode == "mock"
        }
        return (try? await registerIfNeeded())?.mode == "mock"
    }

    /// The current device token, if any — memory first, then the Keychain.
    /// Never touches the network (the AI proxy's per-call token read must stay
    /// cheap); registration happens elsewhere.
    public func registeredToken() -> String? {
        if let creds = credentials { return creds.deviceToken }
        if let stored = try? tokenStore.load() {
            credentials = stored
            return stored.deviceToken
        }
        return nil
    }

    /// Force a fresh identity: mint a NEW registration first and only then
    /// replace the stored credentials (Keychain too). Returns the new token,
    /// or nil when the backend is unreachable — in which case the OLD identity
    /// survives untouched (dropping it before a mint that then fails would
    /// orphan the server-side entitlement, connections, and oplog on the next
    /// launch). `commit` fires the existing `onReRegistered` handler, so the
    /// sync engine's cursor reset keeps working untouched.
    public func refreshRegistration() async -> String? {
        guard let fresh = try? await mintCredentials() else { return nil }
        commit(fresh)
        return fresh.deviceToken
    }

    // MARK: - API surface

    public func createConnectLink(platform: Platform) async throws -> ConnectLink {
        try await authed("POST", "/api/connect/link",
                         body: ["platform": platform.rawValue])
    }

    /// `verify: true` asks the backend to liveness-check each connection against
    /// the provider (TTL-throttled server-side) before returning the snapshot.
    /// An older server simply ignores the param.
    public func accounts(verify: Bool = false) async throws -> [ConnectionInfo] {
        let envelope: AccountsEnvelope = try await authed(
            "GET", "/api/accounts", query: verify ? [("verify", "1")] : [])
        return envelope.connections
    }

    public func disconnect(id: String) async throws {
        let _: OkEnvelope = try await authed("DELETE", "/api/accounts", query: [("id", id)])
    }

    public func pause(id: String, paused: Bool) async throws {
        let _: OkEnvelope = try await authed("PATCH", "/api/accounts", query: [("id", id)],
                                             body: ["action": paused ? "pause" : "resume"])
    }

    /// Halt an in-progress history import: the backend flips the connection to
    /// connected (keeping whatever imported so far) and its backfill loop bails.
    public func stopBackfill(id: String) async throws {
        let _: OkEnvelope = try await authed("PATCH", "/api/accounts", query: [("id", id)],
                                             body: ["action": "stop"])
    }

    /// Re-run the deep (2-month) history import for an already-connected platform.
    public func rebackfill(platform: Platform) async throws {
        let _: OkEnvelope = try await authed("POST", "/api/connect/rebackfill",
                                             body: ["platform": platform.rawValue])
    }

    public func pull(since: String, limit: Int = 500) async throws -> WireBatch {
        try await authed("GET", "/api/sync/pull",
                         query: [("since", since.isEmpty ? "0" : since), ("limit", String(limit))])
    }

    public func send(platform: Platform, platformThreadID: String, text: String,
                     idempotencyKey: String) async throws -> WireMessage {
        let envelope: SendEnvelope = try await authed("POST", "/api/sync/send", body: [
            "platform": platform.rawValue,
            "platformThreadID": platformThreadID,
            "text": text,
            "idempotencyKey": idempotencyKey,
        ])
        return envelope.message
    }

    /// Public-profile bundle for one person (LinkedIn + web, server-side keys).
    public func enrichPerson(_ enrichRequest: WireEnrichRequest) async throws -> WireEnrichment {
        try await authed("POST", "/api/enrich/person",
                         bodyData: try JSONEncoder.osmoWire.encode(enrichRequest))
    }

    // MARK: - Billing / entitlement

    /// This device's backend id (needed to bind a verified entitlement).
    public func deviceID() async throws -> String { try await registerIfNeeded().deviceId }

    /// Fetch a fresh signed entitlement, optionally redeeming a license key.
    public func validateLicense(licenseKey: String? = nil) async throws -> WireEntitlement {
        try await authed("POST", "/api/license/validate",
                         body: licenseKey.map { ["licenseKey": $0] } ?? [:])
    }

    /// Start the server-recorded trial; returns the fresh signed entitlement.
    public func startServerTrial() async throws -> WireEntitlement {
        try await authed("POST", "/api/trial/start", body: [:])
    }

    /// Dev/testing only: clear this device's subscription + trial (keyless mode).
    public func resetLicense() async throws -> WireEntitlement {
        try await authed("POST", "/api/license/reset", body: [:])
    }

    /// Create a checkout session → the URL the app opens to subscribe.
    public func createCheckout(plan: String) async throws -> WireCheckout {
        try await authed("POST", "/api/checkout/session", body: ["plan": plan])
    }

    /// Redeem a referral/promo code → the fresh signed entitlement.
    public func redeemPromo(code: String) async throws -> WireEntitlement {
        try await authed("POST", "/api/promo/redeem", body: ["code": code])
    }

    /// Remote feature flags + kill-switch (public config).
    public func featureFlags() async throws -> [String: Bool] {
        let wire: WireFlags = try await authed("GET", "/api/config/flags")
        return wire.flags
    }

    /// Service health — drives the app's incident banner.
    public func health() async throws -> WireHealth {
        try await authed("GET", "/api/health")
    }

    // MARK: - Account

    /// Link THIS device to a user account after Sign in with Apple. The server
    /// finds-or-creates the user for this Apple identity, attaches the device,
    /// merges any anonymous subscription, and returns the user + a fresh signed
    /// entitlement reflecting the account. After this the same account +
    /// subscription is shared with the website.
    public func linkAccount(appleUserID: String, email: String?, fullName: String?) async throws -> WireAccountLink {
        var body: [String: String] = ["appleUserID": appleUserID]
        if let email, !email.isEmpty { body["email"] = email }
        if let fullName, !fullName.isEmpty { body["fullName"] = fullName }
        return try await authed("POST", "/api/account/link", body: body)
    }

    /// Permanently purge this device's server-side record (account deletion).
    public func deleteAccount() async throws {
        let _: OkEnvelope = try await authed("POST", "/api/account/delete", body: [:])
    }

    /// Send a feedback / bug report. `meta` carries opt-in diagnostics.
    @discardableResult
    public func sendFeedback(message: String, meta: String?) async throws -> Bool {
        var body = ["message": message]
        if let meta { body["meta"] = meta }
        let env: OkEnvelope = try await authed("POST", "/api/feedback", body: body)
        return env.ok
    }

    /// One attachment's raw bytes through the backend's binary media proxy —
    /// not JSON, so it bypasses `authed<T: Decodable>` and returns `Data`
    /// directly (same 401→re-register→retry-once policy as every other call).
    public func fetchMedia(platform: Platform, messageRef: String,
                           attachmentRef: String, mime: String? = nil) async throws -> Data {
        var creds = try await registerIfNeeded()
        var query: [(String, String)] = [
            ("platform", platform.rawValue), ("messageRef", messageRef), ("attachmentRef", attachmentRef),
        ]
        if let mime { query.append(("mime", mime)) }

        for attempt in 0..<2 {
            let req = request("GET", "/api/media", query: query, token: creds.deviceToken)
            let (data, response) = try await transport(req)
            if response.statusCode == 401 && attempt == 0 {
                dropCredentials()
                creds = try await register()
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw BackendError.badStatus(response.statusCode)
            }
            return data
        }
        throw BackendError.notRegistered
    }

    /// A profile-avatar's bytes through the authenticated media proxy. The app
    /// can't GET LinkedIn/Instagram signed CDN URLs directly (they 403 an
    /// unauthenticated request), so avatars for non-connections never loaded;
    /// the proxy fetches them server-side. Returns nil (not throw) on any miss —
    /// a missing avatar just falls back to a monogram, never an error.
    public func fetchAvatar(url: String) async -> Data? {
        guard let creds = try? await registerIfNeeded() else { return nil }
        let req = request("GET", "/api/media", query: [("mode", "avatar"), ("url", url)],
                          token: creds.deviceToken)
        guard let (data, response) = try? await transport(req),
              (200..<300).contains(response.statusCode) else { return nil }
        return data
    }

    // MARK: - SSE events

    /// Long-lived doorbell stream with automatic reconnect. Never finishes
    /// until the consuming task is cancelled.
    public nonisolated func events() -> AsyncStream<BackendEvent> {
        AsyncStream { continuation in
            let task = Task {
                var backoff: Double = 1
                while !Task.isCancelled {
                    do {
                        let creds = try await self.registerIfNeeded()
                        var request = URLRequest(url: self.baseURL.appendingPathComponent("api/events"))
                        request.setValue("Bearer \(creds.deviceToken)", forHTTPHeaderField: "Authorization")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = 90   // heartbeat is 25s; silence >90s = dead

                        let stream = try await self.streamBytes(request)
                        continuation.yield(.streamOpened)
                        var parser = SSEParser()
                        for try await chunk in stream {
                            if Task.isCancelled { break }
                            for frame in parser.feed(chunk) {
                                backoff = 1   // any parsed frame proves liveness
                                if frame.isComment { continuation.yield(.heartbeat); continue }
                                if let event = BackendEvent.decode(frame.data) {
                                    continuation.yield(event)
                                }
                            }
                        }
                    } catch {
                        // 401 mid-stream → drop creds so the next loop re-registers.
                        if let backendError = error as? BackendError,
                           backendError == .badStatus(401) {
                            await self.dropCredentials()
                        }
                    }
                    continuation.yield(.streamClosed)
                    if Task.isCancelled { break }
                    let jitter = Double.random(in: 0.8...1.2)
                    try? await Task.sleep(for: .seconds(backoff * jitter))
                    backoff = min(backoff * 2, 60)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamBytes(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        try await byteStream(request)
    }

    private func dropCredentials() {
        credentials = nil
        try? tokenStore.clear()
    }

    // MARK: - Plumbing

    private struct OkEnvelope: Codable { var ok: Bool }

    private func request(_ method: String, _ path: String,
                         query: [(String, String)] = [],
                         bodyData: Data? = nil,
                         token: String? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Authenticated JSON call with the 401 → re-register → retry-once policy.
    private func authed<T: Decodable>(_ method: String, _ path: String,
                                      query: [(String, String)] = [],
                                      body: [String: String]? = nil) async throws -> T {
        try await authed(method, path, query: query,
                         bodyData: body.map { try! JSONSerialization.data(withJSONObject: $0) })
    }

    /// Same policy, raw JSON body — for request shapes richer than [String: String].
    private func authed<T: Decodable>(_ method: String, _ path: String,
                                      query: [(String, String)] = [],
                                      bodyData: Data?) async throws -> T {
        var creds = try await registerIfNeeded()

        for attempt in 0..<2 {
            let req = request(method, path, query: query, bodyData: bodyData, token: creds.deviceToken)
            let (data, response) = try await transport(req)
            if response.statusCode == 401 && attempt == 0 {
                dropCredentials()
                creds = try await register()   // register() fires onReRegistered
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw BackendError.badStatus(response.statusCode)
            }
            return try JSONDecoder.osmoWire.decode(T.self, from: data)
        }
        throw BackendError.notRegistered
    }

    // MARK: - Production transports

    private static let urlSessionTransport: DataTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        return (data, http)
    }

    private static let urlSessionByteStream: ByteStream = { request in
        // Dedicated config: no cache, generous read window for the long-poll.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        guard http.statusCode == 200 else { throw BackendError.badStatus(http.statusCode) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Chunk by line groups: accumulate bytes, hand off as they come.
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Flush on newline to keep latency low without per-byte yields.
                        if byte == 0x0A {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
        }
    }
}
