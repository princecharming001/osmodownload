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
        let (data, response) = try await transport(request("POST", "/api/device/register"))
        guard response.statusCode == 200 else { throw BackendError.badStatus(response.statusCode) }
        let creds = try JSONDecoder.osmoWire.decode(DeviceCredentials.self, from: data)
        credentials = creds
        try? tokenStore.store(creds)
        return creds
    }

    /// True once registered against a keyless backend (drives the demo banner).
    public func isMockMode() async -> Bool {
        (try? await registerIfNeeded())?.mode == "mock"
    }

    // MARK: - API surface

    public func createConnectLink(platform: Platform) async throws -> ConnectLink {
        try await authed("POST", "/api/connect/link",
                         body: ["platform": platform.rawValue])
    }

    public func accounts() async throws -> [ConnectionInfo] {
        let envelope: AccountsEnvelope = try await authed("GET", "/api/accounts")
        return envelope.connections
    }

    public func disconnect(id: String) async throws {
        let _: OkEnvelope = try await authed("DELETE", "/api/accounts", query: [("id", id)])
    }

    public func pause(id: String, paused: Bool) async throws {
        let _: OkEnvelope = try await authed("PATCH", "/api/accounts", query: [("id", id)],
                                             body: ["action": paused ? "pause" : "resume"])
    }

    public func pull(since: String, limit: Int = 500) async throws -> WireBatch {
        try await authed("GET", "/api/sync/pull",
                         query: [("since", since.isEmpty ? "0" : since), ("limit", String(limit))])
    }

    public func send(platform: Platform, platformThreadID: String, text: String) async throws -> WireMessage {
        let envelope: SendEnvelope = try await authed("POST", "/api/sync/send", body: [
            "platform": platform.rawValue,
            "platformThreadID": platformThreadID,
            "text": text,
        ])
        return envelope.message
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
        let bodyData = body.map { try! JSONSerialization.data(withJSONObject: $0) }
        var creds = try await registerIfNeeded()

        for attempt in 0..<2 {
            let req = request(method, path, query: query, bodyData: bodyData, token: creds.deviceToken)
            let (data, response) = try await transport(req)
            if response.statusCode == 401 && attempt == 0 {
                dropCredentials()
                creds = try await register()
                onReRegistered?()
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
