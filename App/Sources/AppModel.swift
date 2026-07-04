import Foundation
import SwiftUI
import OsmoCore
import OsmoBrain

/// A person as the UI shows them: identity + where the conversation stands.
struct PersonRow: Identifiable, Sendable {
    var id: UUID
    var name: String
    var avatar: Data?
    var status: TextingStatus
    var platforms: [Platform]
}

/// The app's single source of truth. Owns the store + suggestion service, loads
/// data, assembles the morning queue, and drives suggestions. `@MainActor` so
/// views bind directly.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case queue = "Morning"
        case people = "People"
        case projects = "Projects"
        case inbox = "Inbox"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .queue: return "sun.max"
            case .people: return "person.2"
            case .projects: return "target"
            case .inbox: return "tray.full"
            }
        }
    }

    let store: OsmoStore
    @Published private(set) var service: SuggestionService
    @Published var config: RuntimeConfig

    @Published var section: Section = .queue
    @Published var people: [PersonRow] = []
    @Published var queue: [QueueCard] = []
    @Published var projects: [Project] = []
    @Published var threads: [OsmoThread] = []
    @Published var searchText: String = ""
    @Published var searchResults: [OsmoMessage] = []
    @Published var syncing = false
    @Published var lastSyncSummary: String?

    private let syncCoordinator: SyncCoordinator

    init() {
        // Local encrypted store in Application Support (SQLCipher, key from the
        // Keychain), falling back to in-memory so the app is always constructible.
        // If a plaintext DB from a pre-encryption dev build is present, opening it
        // with a key fails — retire it so the encrypted store can take over (safe:
        // no shipped data yet; real data lands only after re-sync).
        let url = Self.storeURL()
        let key = try? KeychainDBKey.loadOrCreate()
        let store = Self.openEncrypted(url: url, key: key)
        self.store = store
        let config = Self.loadConfig()
        self.config = config
        self.service = config.makeService()   // live proxy when reachable, mock otherwise
        self.syncCoordinator = SyncCoordinator(store: store)
        reload()
    }

    /// Persist a new runtime config and rebuild the suggestion service.
    func updateConfig(_ new: RuntimeConfig) {
        config = new
        Self.saveConfig(new)
        service = new.makeService()
    }

    static func storeURL() -> URL { supportDir().appendingPathComponent("osmo.db") }
    static func configURL() -> URL { supportDir().appendingPathComponent("config.json") }

    /// Open the encrypted store; on failure (e.g. a leftover plaintext DB that the
    /// key can't decrypt) retire the old file and retry, then fall back to in-memory.
    private static func openEncrypted(url: URL, key: String?) -> OsmoStore {
        if let s = try? OsmoStore(url: url, passphrase: key) { return s }
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ext))
        }
        return (try? OsmoStore(url: url, passphrase: key)) ?? (try! OsmoStore.inMemory())
    }

    private static func supportDir() -> URL {
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
            return RuntimeConfig()   // defaults → local dev proxy
        }
        return cfg
    }

    static func saveConfig(_ config: RuntimeConfig) {
        if let data = try? JSONEncoder().encode(config) { try? data.write(to: configURL()) }
    }

    /// Pull the latest from every connected reader into the store, rebuild the
    /// identity graph, and refresh the UI.
    func sync() async {
        syncing = true; defer { syncing = false }
        let summary = await syncCoordinator.syncAll()
        lastSyncSummary = summary
        reload()
    }

    func reload() {
        threads = (try? store.threads()) ?? []
        projects = (try? store.activeProjects()) ?? []
        let snapshots = buildSnapshots()
        queue = MorningQueue.build(snapshots: snapshots, projects: (try? store.activeProjects()) ?? [])
        people = buildPeople(snapshots: snapshots)
    }

    /// Send an approved message. iMessage sends directly via AppleScript on this
    /// Mac (the user granted Automation). Other platforms need their own token
    /// (from OAuth) or are draft-insert only — those return false so the caller
    /// falls back to putting the text on the pasteboard / into the compose box.
    func send(_ text: String, platform: Platform, target: String) async -> Bool {
        do {
            switch platform {
            case .imessage:
                try await IMessageSender().send(text, to: target)
                return true
            default:
                return false   // needs OAuth token or is insert-only → caller copies
            }
        } catch {
            return false
        }
    }

    func runSearch() {
        searchResults = (try? store.search(searchText)) ?? []
    }

    private func buildSnapshots() -> [ThreadSnapshot] {
        threads.compactMap { thread in
            guard let last = try? store.lastMessage(inThread: thread.id) else { return nil }
            let contacts = (try? store.contacts(inThread: thread.id)) ?? []
            let personID = contacts.first?.personID
            let name = thread.title
                ?? contacts.first?.displayName
                ?? contacts.first?.handle
                ?? "Unknown"
            return ThreadSnapshot(
                threadID: thread.id, personID: personID, personName: name,
                platform: thread.platform, isEmpty: false,
                lastFromMe: last.isFromMe, lastMessageAt: last.sentAt,
                myLastReadByThem: last.isFromMe ? last.readAt : nil,
                theirLastText: last.isFromMe ? nil : last.text)
        }
    }

    private func buildPeople(snapshots: [ThreadSnapshot]) -> [PersonRow] {
        // Group snapshots by person (or thread when unresolved), pick the most
        // urgent status per person.
        var rows: [UUID: PersonRow] = [:]
        for s in snapshots {
            let status = TextingStatus.derive(s)
            let key = s.personID ?? s.threadID
            if var existing = rows[key] {
                if rank(status) > rank(existing.status) { existing.status = status }
                if !existing.platforms.contains(s.platform) { existing.platforms.append(s.platform) }
                rows[key] = existing
            } else {
                rows[key] = PersonRow(id: key, name: s.personName, avatar: nil,
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
}
