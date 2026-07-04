import Foundation
import SwiftUI
import AppKit
import OsmoCore
import OsmoBrain
import OsmoShell

/// A person as the UI shows them: identity + where the conversation stands.
struct PersonRow: Identifiable, Sendable {
    var id: UUID
    var name: String
    var avatar: Data?
    var status: TextingStatus
    var platforms: [Platform]
}

/// The app's single source of truth. Owns the store, suggestion service, backend
/// client, connections manager, realtime sync engine, and notifier — every
/// surface hangs off this. `@MainActor` so views bind directly.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case today = "Today"
        case inbox = "Inbox"
        case people = "People"
        case projects = "Projects"
        case connections = "Connections"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .today: return "sun.max"
            case .inbox: return "tray"
            case .people: return "person.2"
            case .projects: return "target"
            case .connections: return "link"
            }
        }
    }

    let store: OsmoStore
    let backend: BackendClient
    let connections: ConnectionsManager
    private let realtime: RealtimeSyncEngine
    let notifier: OsmoNotifier

    @Published private(set) var service: SuggestionService
    @Published var config: RuntimeConfig

    @Published var section: Section = .today
    @Published var people: [PersonRow] = []
    @Published var queue: [QueueCard] = []
    @Published var projects: [Project] = []
    @Published var threads: [OsmoThread] = []
    @Published var searchText: String = ""
    @Published var searchResults: [OsmoMessage] = []
    @Published var syncing = false
    @Published var lastSyncSummary: String?
    @Published var isMockMode = true
    @Published var mergeSuggestions: [MergeSuggestion] = []
    /// Thread currently open in the detail pane (suppresses its notifications).
    @Published var focusedThreadID: UUID?
    /// Inbox selection (also set by Today's "Draft" to deep-link a thread).
    @Published var selectedThreadID: UUID? {
        didSet {
            // A deep-link must never land on a filtered-out thread — clear the
            // platform filter if it would hide the selection.
            if let id = selectedThreadID, let filter = inboxPlatformFilter,
               let thread = threads.first(where: { $0.id == id }), thread.platform != filter {
                inboxPlatformFilter = nil
            }
        }
    }
    /// Inbox platform filter (nil = all). Lives here, not in view @State, so it
    /// survives section switches and view identity churn.
    @Published var inboxPlatformFilter: Platform?
    /// Person detail selection.
    @Published var selectedPersonID: UUID?
    /// A transient toast surfaced by any surface.
    @Published var toast: String?

    private let syncCoordinator: SyncCoordinator

    init() {
        let url = Self.storeURL()
        let key = try? KeychainDBKey.loadOrCreate()
        let store = Self.openEncrypted(url: url, key: key)
        self.store = store
        let config = Self.loadConfig()
        self.config = config
        self.service = config.makeService()
        self.syncCoordinator = SyncCoordinator(store: store)

        let backend = BackendClient(baseURL: config.backendOrigin)
        self.backend = backend
        self.connections = ConnectionsManager(
            client: backend, persistURL: Self.connectionsURL())
        self.realtime = RealtimeSyncEngine(
            store: store, client: backend,
            cursorStore: FileCursorStore(url: Self.cursorURL()))
        self.notifier = OsmoNotifier()

        reload()
        startRealtime()
    }

    // MARK: - Realtime

    private func startRealtime() {
        Task { [weak self] in
            guard let self else { return }
            isMockMode = await backend.isMockMode()
            await realtime.setOnEvent { [weak self] event in
                Task { @MainActor in self?.connections.handle(event) }
            }
            await realtime.start()
            await connections.reconcile()

            // Fresh inbound → notify (rules) + refresh UI. Ends when the engine
            // finishes the stream (stop()), releasing this task. AppModel is a
            // root object (app lifetime), so the loop's strong hold is fine.
            for await inbound in realtime.inbound {
                reload()
                notifier.considerInbound(inbound, focusedThreadID: focusedThreadID,
                                         mutedThreadIDs: mutedThreadIDs(), store: store)
            }
        }
    }

    /// Called on foreground/wake to catch up + re-probe local access.
    func onForeground() {
        connections.probeLocal()
        Task {
            await connections.reconcile()
            await realtime.pullNow()
            await drainSendQueue()
        }
    }

    /// Retry any sends queued while offline. Called on foreground, after a sync,
    /// and after a successful live send. Dequeues on success; drops after too
    /// many attempts so a permanently-failing send can't wedge the queue.
    func drainSendQueue() async {
        let pending = (try? store.queuedSends()) ?? []
        guard !pending.isEmpty else { return }
        var sent = 0
        for item in pending {
            guard let id = item.id else { continue }
            guard connections.canDirectSend(item.platform) else { continue }
            do {
                let message = try await backend.send(
                    platform: item.platform, platformThreadID: item.platformThreadID, text: item.text)
                let normalized = BackendBatchNormalizer.normalize(
                    WireBatch(contacts: [], threads: [], messages: [message], cursor: "", hasMore: false))
                for m in normalized.batch.messages { _ = try? store.ingest(m) }
                try? store.dequeueSend(id: id)
                sent += 1
            } catch {
                try? store.bumpSendAttempt(id: id)
                if item.attempts + 1 >= 5 { try? store.dequeueSend(id: id) }  // give up, don't wedge
            }
        }
        if sent > 0 { reload(); toast = "Sent \(sent) queued message\(sent == 1 ? "" : "s")." }
    }

    private func mutedThreadIDs() -> Set<UUID> {
        // Threads whose platform connection is paused.
        var muted = Set<UUID>()
        for thread in threads {
            if case .paused = connections.phases[thread.platform] { muted.insert(thread.id) }
        }
        return muted
    }

    // MARK: - Config

    func updateConfig(_ new: RuntimeConfig) {
        config = new
        Self.saveConfig(new)
        service = new.makeService()
    }

    // MARK: - Connect

    /// Begin connecting a platform: mint the hosted-auth link and open it.
    func connect(_ platform: Platform) {
        if platform == .imessage {
            openFullDiskAccessSettings()
            return
        }
        Task {
            do {
                let url = try await connections.beginConnect(platform)
                NSWorkspace.shared.open(url)
            } catch {
                toast = "Couldn't start the \(platform.displayName) connection."
            }
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Sync + reload

    func sync() async {
        syncing = true; defer { syncing = false }
        let summary = await syncCoordinator.syncAll()
        lastSyncSummary = summary
        await realtime.pullNow()
        reload()
    }

    func reload() {
        let snoozed = (try? store.snoozedThreadIDs()) ?? []
        threads = ((try? store.threads()) ?? []).filter { !snoozed.contains($0.id) }
        projects = (try? store.activeProjects()) ?? []
        mergeSuggestions = (try? store.rebuildIdentityGraph()) ?? []
        let snapshots = buildSnapshots()
        queue = MorningQueue.build(snapshots: snapshots, projects: projects)
        people = buildPeople(snapshots: snapshots)
    }

    // MARK: - Send (dynamic routing)

    /// Send an approved message. Routing:
    ///  - iMessage → local AppleScript send.
    ///  - a platform with a LIVE backend connection → send through the backend
    ///    (returns the real message), then ingest the echo.
    ///  - else → false (caller copies / inserts).
    @discardableResult
    func send(_ text: String, platform: Platform, target: String) async -> Bool {
        if platform == .imessage {
            do { try await IMessageSender().send(text, to: target); return true }
            catch { return false }
        }
        guard connections.canDirectSend(platform), !target.isEmpty else { return false }
        do {
            let message = try await backend.send(platform: platform, platformThreadID: target, text: text)
            let normalized = BackendBatchNormalizer.normalize(
                WireBatch(contacts: [], threads: [], messages: [message], cursor: "", hasMore: false))
            for m in normalized.batch.messages { _ = try? store.ingest(m) }
            reload()
            // A successful live send is a good moment to flush anything queued.
            await drainSendQueue()
            return true
        } catch {
            // Offline → queue for later drain (onForeground / next sync / next send).
            try? store.enqueueSend(QueuedSend(
                id: nil, platform: platform, platformThreadID: target,
                text: text, queuedAt: Date(), attempts: 0))
            toast = "Offline — queued to send when you're back."
            return false
        }
    }

    func runSearch() {
        searchResults = searchText.isEmpty ? [] : ((try? store.search(searchText)) ?? [])
    }

    // MARK: - Snapshots

    /// Avatar for a person/thread row, from the first contact that has a photo.
    private var avatarByKey: [UUID: Data] = [:]

    private func buildSnapshots() -> [ThreadSnapshot] {
        avatarByKey = [:]
        return threads.compactMap { thread in
            guard let last = try? store.lastMessage(inThread: thread.id) else { return nil }
            let contacts = (try? store.contacts(inThread: thread.id)) ?? []
            let personID = contacts.first?.personID
            let name = (thread.title?.isEmpty == false ? thread.title : nil)
                ?? contacts.first?.displayLabel ?? "New conversation"
            // Cache an avatar under the person/thread key for buildPeople.
            if let avatar = contacts.first(where: { $0.avatarData != nil })?.avatarData {
                avatarByKey[personID ?? thread.id] = avatar
            }
            return ThreadSnapshot(
                threadID: thread.id, personID: personID, personName: name,
                platform: thread.platform, isEmpty: false,
                lastFromMe: last.isFromMe, lastMessageAt: last.sentAt,
                myLastReadByThem: last.isFromMe ? last.readAt : nil,
                theirLastText: last.isFromMe ? nil : last.text)
        }
    }

    private func buildPeople(snapshots: [ThreadSnapshot]) -> [PersonRow] {
        var rows: [UUID: PersonRow] = [:]
        for s in snapshots {
            let status = TextingStatus.derive(s)
            let key = s.personID ?? s.threadID
            if var existing = rows[key] {
                if rank(status) > rank(existing.status) { existing.status = status }
                if !existing.platforms.contains(s.platform) { existing.platforms.append(s.platform) }
                rows[key] = existing
            } else {
                rows[key] = PersonRow(id: key, name: s.personName, avatar: avatarByKey[key],
                                      status: status, platforms: [s.platform])
            }
        }
        return rows.values.sorted { rank($0.status) > rank($1.status) }
    }

    private func rank(_ s: TextingStatus) -> Int {
        switch s {
        case .needsReply: return 5
        case .leftOnRead: return 4
        case .waiting: return 3
        case .ghosted: return 2
        case .quiet: return 1
        case .sayHi: return 0
        }
    }

    // MARK: - Paths + persistence

    static func storeURL() -> URL { supportDir().appendingPathComponent("osmo.db") }
    static func configURL() -> URL { supportDir().appendingPathComponent("config.json") }
    static func connectionsURL() -> URL { supportDir().appendingPathComponent("connections.json") }
    static func cursorURL() -> URL { supportDir().appendingPathComponent("cursors.json") }

    private static func openEncrypted(url: URL, key: String?) -> OsmoStore {
        if let s = try? OsmoStore(url: url, passphrase: key) { return s }
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ext))
        }
        return (try? OsmoStore(url: url, passphrase: key)) ?? (try! OsmoStore.inMemory())
    }

    static func supportDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Osmo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func loadConfig() -> RuntimeConfig {
        guard let data = try? Data(contentsOf: configURL()),
              let cfg = try? JSONDecoder().decode(RuntimeConfig.self, from: data) else {
            return RuntimeConfig()
        }
        return cfg
    }

    static func saveConfig(_ config: RuntimeConfig) {
        if let data = try? JSONEncoder().encode(config) { try? data.write(to: configURL()) }
    }

    // MARK: - Data management (Settings → Privacy)

    func exportData() -> Data? { try? store.exportJSON() }

    func deleteAllData() {
        try? store.deleteAllData()
        try? KeychainDeviceToken().clear()
        UserDefaults.standard.removeObject(forKey: "hasOnboarded")
        reload()
        toast = "All local data erased."
    }
}
