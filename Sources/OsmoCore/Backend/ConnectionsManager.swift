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
        guard let id = connectionIDs[platform] else { return }
        try? await client.pause(id: id, paused: paused)
        apply(platform, .statusEvent(paused ? "paused" : "connected"))
    }

    public func disconnect(_ platform: Platform) async {
        guard let id = connectionIDs[platform] else { return }
        try? await client.disconnect(id: id)
        connectionIDs[platform] = nil
        apply(platform, .statusEvent("disconnected"))
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
        for platform in Platform.allCases where platform.access != .localData {
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

    /// Local probes (iMessage FDA). Cheap; run on init, reconcile, foreground.
    public func probeLocal() {
        let readable = FileManager.default.isReadableFile(atPath: chatDBPath.path)
        phases[.imessage] = readable ? .live : .notConnected
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
            // Transient phases don't survive a relaunch meaningfully.
            switch phase {
            case .linking, .backfilling: out[platform] = .notConnected
            default: out[platform] = phase
            }
        }
        return out
    }
}
