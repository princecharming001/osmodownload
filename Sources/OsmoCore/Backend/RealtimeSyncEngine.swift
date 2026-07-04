import Foundation

/// Where the backend cursor + local watermarks persist between launches.
public protocol CursorStoring: Sendable {
    func loadBackendCursor() -> String
    func saveBackendCursor(_ cursor: String)
    func loadChatDBRowID() -> Int64
    func saveChatDBRowID(_ rowID: Int64)
}

/// JSON-file cursor store (Application Support, next to the config).
public struct FileCursorStore: CursorStoring {
    private struct State: Codable { var backendCursor: String; var chatDBRowID: Int64 }
    private let url: URL
    public init(url: URL) { self.url = url }

    private func load() -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State(backendCursor: "", chatDBRowID: 0) }
        return state
    }
    private func save(_ state: State) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
    public func loadBackendCursor() -> String { load().backendCursor }
    public func saveBackendCursor(_ cursor: String) {
        var s = load(); s.backendCursor = cursor; save(s)
    }
    public func loadChatDBRowID() -> Int64 { load().chatDBRowID }
    public func saveChatDBRowID(_ rowID: Int64) {
        var s = load(); s.chatDBRowID = rowID; save(s)
    }
}

/// In-memory cursors for tests.
public final class MemoryCursorStore: CursorStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = ""
    private var rowID: Int64 = 0
    public init() {}
    public func loadBackendCursor() -> String { lock.lock(); defer { lock.unlock() }; return cursor }
    public func saveBackendCursor(_ c: String) { lock.lock(); defer { lock.unlock() }; cursor = c }
    public func loadChatDBRowID() -> Int64 { lock.lock(); defer { lock.unlock() }; return rowID }
    public func saveChatDBRowID(_ r: Int64) { lock.lock(); defer { lock.unlock() }; rowID = r }
}

/// The resident sync daemon — three source loops into one ingest path:
///
///  1. **Local iMessage poll** (~3s): `ChatDBReader.readSince(rowID:)` off the
///     monotonic ROWID watermark; normalize; ingest.
///  2. **SSE doorbell**: `sync.dirty` → debounced `pullNow()`. Connection/
///     backfill events are forwarded to the app (ConnectionsManager).
///  3. **Reconciliation** (60s + on wake): `pullNow()` regardless of SSE health
///     — polling is the source of truth, SSE is the latency optimization.
///
/// `pullNow()` pages `pull(since:)` while `hasMore`, normalizes, ingests in FK
/// order, yields fresh inbound messages (notifications/UI), and persists the
/// cursor ONLY after ingest (crash between = harmless idempotent re-pull).
public actor RealtimeSyncEngine {

    public struct NewInbound: Sendable, Equatable {
        public var message: OsmoMessage
        public var threadID: UUID
    }

    private let store: OsmoStore
    private let client: BackendClient
    private let cursorStore: CursorStoring
    private let iMessageDBPath: URL
    private let reconcileInterval: Duration
    private let localPollInterval: Duration
    private let freshWindow: TimeInterval

    private var loops: [Task<Void, Never>] = []
    private var pullDebounce: Task<Void, Never>?
    private var identityDebounce: Task<Void, Never>?
    private var chatReader: ChatDBReader?
    private var started = false
    /// macOS Contacts index (handle → name + photo), built once per session so
    /// iMessage threads show real names/avatars, not raw phone numbers.
    private var contactsIndex: [String: ResolvedContact] = [:]
    private var contactsIndexBuilt = false
    /// url → downloaded avatar bytes, so a profile picture is fetched once.
    private var avatarCache: [String: Data] = [:]

    private var inboundContinuation: AsyncStream<NewInbound>.Continuation?
    public private(set) nonisolated(unsafe) var inbound: AsyncStream<NewInbound>!

    /// Forwarded connection/backfill events (the app hands these to
    /// ConnectionsManager on the main actor).
    public var onEvent: (@Sendable (BackendEvent) -> Void)?
    public func setOnEvent(_ handler: @escaping @Sendable (BackendEvent) -> Void) {
        onEvent = handler
    }

    public init(store: OsmoStore,
                client: BackendClient,
                cursorStore: CursorStoring,
                iMessageDBPath: URL = SyncCoordinator.defaultChatDBPath,
                reconcileInterval: Duration = .seconds(60),
                localPollInterval: Duration = .seconds(3),
                freshInboundWindow: TimeInterval = 15 * 60) {
        self.store = store
        self.client = client
        self.cursorStore = cursorStore
        self.iMessageDBPath = iMessageDBPath
        self.reconcileInterval = reconcileInterval
        self.localPollInterval = localPollInterval
        self.freshWindow = freshInboundWindow

        var continuation: AsyncStream<NewInbound>.Continuation!
        self.inbound = AsyncStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !started else { return }
        started = true

        // On a 401-driven re-registration the backend state is fresh — reset
        // the cursor so everything re-pulls (idempotent by construction).
        await client.setOnReRegistered { [cursorStore] in
            cursorStore.saveBackendCursor("")
        }

        // 1. SSE doorbell loop.
        loops.append(Task { [weak self] in
            guard let self else { return }
            for await event in await self.client.events() {
                if Task.isCancelled { break }
                await self.route(event)
            }
        })

        // 2. Reconciliation loop.
        loops.append(Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pullNow()
                try? await Task.sleep(for: await self.reconcileInterval)
            }
        })

        // 3. Local iMessage poll loop.
        loops.append(Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollChatDB()
                try? await Task.sleep(for: await self.localPollInterval)
            }
        })
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops.removeAll()
        pullDebounce?.cancel()
        identityDebounce?.cancel()
        inboundContinuation?.finish()   // let the app's `for await` consumer exit
        started = false
    }

    // MARK: - Backend pull path

    private func route(_ event: BackendEvent) {
        switch event {
        case .syncDirty:
            schedulePull()
        case .streamOpened:
            // Catch up on anything missed while the stream was down.
            schedulePull()
            onEvent?(event)
        default:
            onEvent?(event)
        }
    }

    /// Debounce doorbells (a backfill rings many times in one second).
    private func schedulePull() {
        pullDebounce?.cancel()
        pullDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.pullNow()
        }
    }

    public func pullNow() async {
        var cursor = cursorStore.loadBackendCursor()
        var wroteAny = false

        while true {
            guard let wire = try? await client.pull(since: cursor) else { return }
            var result = BackendBatchNormalizer.normalize(wire)
            result.batch.contacts = await fetchAvatars(for: result.batch.contacts, wire: wire.contacts)
            let fresh = ingest(result.batch)
            wroteAny = wroteAny || !fresh.isEmpty
            for inbound in fresh { inboundContinuation?.yield(inbound) }

            cursor = wire.cursor
            cursorStore.saveBackendCursor(cursor)   // AFTER ingest — crash-safe order
            if !wire.hasMore { break }
        }

        if wroteAny { scheduleIdentityRebuild() }
    }

    /// FK-order ingest; returns fresh *inbound* messages (new, not from me,
    /// recent) for notification/UI purposes.
    private func ingest(_ batch: NormalizedBatch) -> [NewInbound] {
        var fresh: [NewInbound] = []
        for contact in batch.contacts { _ = try? store.ingest(contact) }
        for thread in batch.threads { _ = try? store.ingest(thread) }
        for message in batch.messages {
            let isNew = (try? store.ingest(message)) ?? false
            // Notify only for genuinely-fresh inbound: new to us, from them, recent,
            // and NOT already read (a re-emit that merely adds a read receipt must
            // not re-notify — gate on readAt too).
            if isNew && !message.isFromMe && message.readAt == nil
                && message.sentAt > Date().addingTimeInterval(-freshWindow) {
                fresh.append(NewInbound(message: message, threadID: message.threadID))
            }
        }
        return fresh
    }

    /// Trailing debounce with a leading anchor: if a rebuild is already pending we
    /// leave it, so it still fires ~5s after the FIRST trigger even during an
    /// active conversation (a 3s poll cadence would otherwise starve a pure
    /// trailing debounce forever).
    private func scheduleIdentityRebuild() {
        if let identityDebounce, !identityDebounce.isCancelled { return }
        identityDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.storeRebuild()
            await self.clearIdentityDebounce()
        }
    }
    private func clearIdentityDebounce() { identityDebounce = nil }
    private func storeRebuild() throws -> [MergeSuggestion] {
        try store.rebuildIdentityGraph()
    }

    // MARK: - Local iMessage poll path

    /// Download profile pictures for API contacts (Slack/LinkedIn/etc.) and set
    /// them on the matching normalized contacts. Cached by URL; bounded so a bad
    /// image can't stall the pull. Names already arrive from the provider.
    private func fetchAvatars(for contacts: [OsmoContact], wire: [WireContact]) async -> [OsmoContact] {
        // handle key → avatar URL from the wire.
        var urlByKey: [String: String] = [:]
        for w in wire {
            if let url = w.avatarUrl, !url.isEmpty { urlByKey["\(w.platform):\(w.handle)"] = url }
        }
        guard !urlByKey.isEmpty else { return contacts }

        var out = contacts
        for i in out.indices where out[i].avatarData == nil {
            guard let url = urlByKey["\(out[i].platform.rawValue):\(out[i].handle)"] else { continue }
            if let cached = avatarCache[url] { out[i].avatarData = cached; continue }
            guard let u = URL(string: url) else { continue }
            var req = URLRequest(url: u); req.timeoutInterval = 8
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 {
                avatarCache[url] = data
                out[i].avatarData = data
            }
        }
        return out
    }

    /// Enrich iMessage contacts (and 1:1 thread titles) with names + photos from
    /// the macOS address book. Handles that aren't in Contacts keep their raw
    /// value; the UI prettifies those (never "Unknown").
    private func enrichWithContacts(_ batch: NormalizedBatch) -> NormalizedBatch {
        if !contactsIndexBuilt {
            contactsIndex = ContactsResolver.buildIndex()
            contactsIndexBuilt = true
        }
        guard !contactsIndex.isEmpty else { return batch }

        var enrichedContacts = batch.contacts
        for i in enrichedContacts.indices {
            let key = HandleNormalizer.normalize(enrichedContacts[i].handle).value
            guard let resolved = contactsIndex[key] else { continue }
            enrichedContacts[i].displayName = resolved.name
            if enrichedContacts[i].avatarData == nil { enrichedContacts[i].avatarData = resolved.imageData }
        }

        var result = batch
        result.contacts = enrichedContacts
        return result
    }

    private func pollChatDB() {
        if chatReader == nil {
            // Reader opens lazily; FDA may be granted mid-session.
            guard FileManager.default.isReadableFile(atPath: iMessageDBPath.path),
                  let reader = try? ChatDBReader(path: iMessageDBPath) else { return }
            chatReader = reader
        }
        guard let reader = chatReader else { return }

        // Watermark 0 = first launch → readSince(0) imports the FULL history in
        // this pass (the store dedups), then advances the ROWID so later polls
        // only deliver new rows. Fresh-inbound notifications are gated on recency
        // in ingest(), so a first-run bulk import doesn't spam notifications.
        let watermark = cursorStore.loadChatDBRowID()
        guard let (rows, maxRowID) = try? reader.readSince(rowID: watermark), !rows.isEmpty else { return }

        let batch = enrichWithContacts(IMessageNormalizer.normalize(rows))
        let fresh = ingest(batch)
        cursorStore.saveChatDBRowID(maxRowID)   // AFTER ingest — crash-safe order
        for inbound in fresh { inboundContinuation?.yield(inbound) }
        if !fresh.isEmpty { scheduleIdentityRebuild() }
    }
}
