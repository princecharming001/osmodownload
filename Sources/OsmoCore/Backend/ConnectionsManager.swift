import Foundation
import Observation

/// Owns the per-platform connection phases the UI renders. Backend-driven
/// states are canonical (SSE events + reconciliation snapshots through the
/// pure reducer); local platforms enter through probes:
///  - iMessage: chat.db readable (Full Disk Access) → live / notConnected
///  - platforms with no backend connection fall back to "works through the
///    pill" when Accessibility is granted (the retained screen-read path).
@MainActor
public final class ConnectionsManager: ObservableObject {

    @Published public private(set) var phases: [Platform: ConnectionPhase] = [:]
    @Published public private(set) var lastReconcile: Date?

    private let client: BackendClient
    private let persistURL: URL
    private var connectionIDs: [Platform: String] = [:]   // backend connection id per platform
    private let chatDBPath: URL

    public init(client: BackendClient, persistURL: URL,
                chatDBPath: URL = SyncCoordinator.defaultChatDBPath) {
        self.client = client
        self.persistURL = persistURL
        self.chatDBPath = chatDBPath
        self.phases = Self.loadPersisted(persistURL) ?? Self.initialPhases()
        probeLocal()
    }

    private static func initialPhases() -> [Platform: ConnectionPhase] {
        Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0, .notConnected) })
    }

    // MARK: - User actions

    /// Start the connect flow. Returns the hosted-auth/OAuth URL for the App
    /// layer to open (NSWorkspace stays out of OsmoCore).
    public func beginConnect(_ platform: Platform) async throws -> URL {
        let link = try await client.createConnectLink(platform: platform)
        guard let url = URL(string: link.url) else { throw BackendClient.BackendError.invalidResponse }
        apply(platform, .beginLink(now: Date()))
        return url
    }

    public func pause(_ platform: Platform, paused: Bool) async {
        // iMessage is local: pause = stop the poller + hold a paused phase that
        // probeLocal must NOT auto-flip back to live; resume clears it.
        if platform == .imessage {
            if paused { phases[.imessage] = .paused }
            else { phases[.imessage] = .notConnected; probeLocal() }   // clear → re-probe FDA
            persist()
            return
        }
        // Backend platforms: reflect the tap immediately (optimistic), then tell
        // the backend. connectionIDs don't survive a relaunch, so re-fetch if
        // missing rather than silently no-op'ing (the old bug).
        if connectionIDs[platform] == nil { await reconcile() }
        apply(platform, .statusEvent(paused ? "paused" : "connected"))
        if let id = connectionIDs[platform] { try? await client.pause(id: id, paused: paused) }
    }

    public func disconnect(_ platform: Platform) async {
        if platform == .imessage {
            phases[.imessage] = .disconnected   // held; probeLocal won't revive it
            persist()
            return
        }
        if connectionIDs[platform] == nil { await reconcile() }
        apply(platform, .statusEvent("disconnected"))       // optimistic
        if let id = connectionIDs[platform] { try? await client.disconnect(id: id) }
        connectionIDs[platform] = nil
    }

    /// Stop an in-progress history import mid-way. Keeps whatever's already been
    /// imported and settles the platform to live — the backend backfill loop sees
    /// the flipped status and bails. iMessage imports locally (and fast), so we
    /// just settle it live; the sync engine won't re-pull a paused/live platform.
    public func stopBackfill(_ platform: Platform) async {
        if platform == .imessage {
            phases[.imessage] = .live
            persist()
            return
        }
        if connectionIDs[platform] == nil { await reconcile() }
        apply(platform, .statusEvent("connected"))   // optimistic → live
        if let id = connectionIDs[platform] { try? await client.stopBackfill(id: id) }
    }

    /// Re-run the deep 2-month history import for a live backend platform — for
    /// accounts connected before the deeper window shipped. Shows backfilling
    /// progress via the normal status events. (iMessage is always full, so no-op.)
    public func reimportHistory(_ platform: Platform) async {
        guard platform != .imessage else { return }
        apply(platform, .backfillProgress(0.02))   // reflect the tap immediately
        do { try await client.rebackfill(platform: platform) }
        catch { await reconcile() }                 // heal the phase if it failed
    }

    /// Re-enable a user-paused/disconnected iMessage (the "Reconnect"/"Resume"
    /// path): drop the held phase and re-probe Full Disk Access.
    public func enableLocal() {
        phases[.imessage] = .notConnected
        probeLocal()
        persist()
    }

    /// Whether iMessage polling should run (false while the user has paused or
    /// disconnected it) — the sync engine checks this to stop pulling.
    public var isLocalMuted: Bool {
        phases[.imessage] == .paused || phases[.imessage] == .disconnected
    }

    /// User bailed out of a stuck "waiting for authorization" — reset to
    /// notConnected so the Connect button comes back. Best-effort tells the
    /// backend to drop any half-open connection it may have recorded.
    public func cancelConnect(_ platform: Platform) async {
        if let id = connectionIDs[platform] { try? await client.disconnect(id: id) }
        connectionIDs[platform] = nil
        phases[platform] = .notConnected
        persist()
    }

    // MARK: - Event + reconciliation inputs

    public func handle(_ event: BackendEvent) {
        switch event {
        case .connectionStatus(let platformRaw, let status, let connectionId):
            guard let platform = Platform(rawValue: platformRaw) else { return }
            if !connectionId.isEmpty { connectionIDs[platform] = connectionId }
            apply(platform, .statusEvent(status))
        case .backfillProgress(let platformRaw, let progress):
            guard let platform = Platform(rawValue: platformRaw) else { return }
            apply(platform, .backfillProgress(progress))
        default:
            break
        }
    }

    /// Snapshot-heal from GET /api/accounts: fixes missed webhooks, collapses
    /// stale linking, and detects a dev-server restart (all connections gone).
    public func reconcile() async {
        guard let accounts = try? await client.accounts() else { return }
        let byPlatform = Dictionary(grouping: accounts, by: { Platform(rawValue: $0.platform) })
        // Backend truth drives every platform EXCEPT iMessage (local FDA probe).
        // This deliberately INCLUDES WhatsApp: it's `.localData` access but has no
        // local reader, so its connected state must come from the backend —
        // otherwise a stale persisted `.live` could never be cleared (reconcile
        // used to skip every localData platform), which is one way phantom
        // WhatsApp "Connected" survived on accounts that never linked it.
        for platform in Platform.allCases where platform != .imessage {
            let info = byPlatform[platform]?.first
            if let info { connectionIDs[platform] = info.id }
            apply(platform, .accountsSnapshot(present: info != nil, status: info?.status))
            apply(platform, .linkTimeout(now: Date()))
            if let info, info.status == "backfilling" {
                apply(platform, .backfillProgress(info.backfillProgress))
            }
        }
        probeLocal()
        lastReconcile = Date()
        persist()
    }

    /// Local probes (iMessage FDA). Uses a REAL open+query, not `isReadableFile`
    /// — chat.db is world-readable at the POSIX layer, so isReadableFile can
    /// mislead; only actually opening it proves Full Disk Access is effective.
    public func probeLocal() {
        // Never override a user's explicit Pause/Disconnect — that was why those
        // buttons "didn't work" for iMessage (probeLocal ran on every foreground /
        // reconcile / import tick and flipped it straight back to live).
        if phases[.imessage] == .paused || phases[.imessage] == .disconnected { return }
        let ok = ChatDBReader.canRead(path: chatDBPath)
        phases[.imessage] = ok ? .live : .notConnected
    }

    /// The platform's backend connection id (send routing needs it).
    public func connectionID(for platform: Platform) -> String? { connectionIDs[platform] }

    /// Dynamic send capability: a live backend connection makes any platform
    /// directly sendable (incl. LinkedIn/IG via the provider); iMessage is
    /// always local-send; otherwise fall back to the static platform rule.
    public func canDirectSend(_ platform: Platform) -> Bool {
        if platform == .imessage { return true }
        if let phase = phases[platform], phase.isActive { return true }
        return false
    }

    // MARK: - Internals

    private func apply(_ platform: Platform, _ input: ConnectionStateMachine.Input) {
        let current = phases[platform] ?? .notConnected
        let next = ConnectionStateMachine.reduce(current, input)
        if next != current {
            phases[platform] = next
            persist()
        }
    }

    private func persist() {
        let snapshot = phases.reduce(into: [String: ConnectionPhase]()) { $0[$1.key.rawValue] = $1.value }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: persistURL, options: .atomic)
        }
    }

    private static func loadPersisted(_ url: URL) -> [Platform: ConnectionPhase]? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode([String: ConnectionPhase].self, from: data)
        else { return nil }
        var out = initialPhases()
        for (raw, phase) in snapshot {
            guard let platform = Platform(rawValue: raw) else { continue }
            out[platform] = rehydrated(phase)
        }
        return out
    }

    /// A persisted phase, sanitized for load. We NEVER resurrect a "connected"
    /// phase from disk — a fresh or relaunched app must re-verify EVERY connection
    /// live: iMessage via the Full-Disk-Access probe, backend platforms via
    /// reconcile against `/api/accounts`. This is the root-cause guard against a
    /// stale `connections.json` showing WhatsApp / LinkedIn / Instagram as
    /// "Connected" on an account that never linked them. User-intent holds
    /// (paused / disconnected) are preserved so we don't silently re-enable them.
    nonisolated static func rehydrated(_ phase: ConnectionPhase) -> ConnectionPhase {
        switch phase {
        case .linking, .backfilling, .live, .degraded: return .notConnected
        case .notConnected, .paused, .disconnected: return phase
        }
    }
}
