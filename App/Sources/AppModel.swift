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
    let service: SuggestionService

    @Published var section: Section = .queue
    @Published var people: [PersonRow] = []
    @Published var queue: [QueueCard] = []
    @Published var projects: [Project] = []
    @Published var threads: [OsmoThread] = []
    @Published var searchText: String = ""
    @Published var searchResults: [OsmoMessage] = []

    init() {
        // Local encrypted store in Application Support; fall back to in-memory so
        // the app is always constructible (e.g. sandboxed first run before the
        // container exists).
        let url = Self.storeURL()
        self.store = (try? OsmoStore(url: url)) ?? (try! OsmoStore.inMemory())
        self.service = SuggestionService(generator: GeneratorRouter(live: nil))
        reload()
    }

    static func storeURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Osmo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("osmo.db")
    }

    func reload() {
        threads = (try? store.threads()) ?? []
        projects = (try? store.activeProjects()) ?? []
        let snapshots = buildSnapshots()
        queue = MorningQueue.build(snapshots: snapshots, projects: (try? store.activeProjects()) ?? [])
        people = buildPeople(snapshots: snapshots)
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
