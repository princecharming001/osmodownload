import Testing
import Foundation
@testable import OsmoCore

/// Opt-in diagnostic (OSMO_INSPECT=1): open the *installed app's* encrypted store
/// and print what's actually in it — distinct platforms + thread/message counts.
/// Answers "does the inbox filter have more than one platform to filter?".
@Suite("Real store inspection (opt-in)")
struct RealStoreInspectionTests {

    @Test("Dump the live app store's platforms",
          .enabled(if: ProcessInfo.processInfo.environment["OSMO_INSPECT"] == "1"))
    func inspect() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Osmo")
        let dbURL = dir.appendingPathComponent("osmo.db")
        let key = try? KeychainDBKey.loadOrCreate()
        let store = try OsmoStore(url: dbURL, passphrase: key)

        let threads = try store.threads(limit: 5000)
        let byPlatform = Dictionary(grouping: threads, by: \.platform)
            .mapValues(\.count)
        print("=== OSMO STORE ===")
        print("total threads:", threads.count)
        print("total messages:", (try? store.messageCount()) ?? -1)
        for (platform, count) in byPlatform.sorted(by: { $0.value > $1.value }) {
            print("  \(platform.rawValue): \(count) threads")
        }
        print("distinct platforms:", byPlatform.keys.count)
        // What the OLD inbox saw (default 500 limit, recency-ordered):
        let top500 = try store.threads()   // default limit 500
        let top500ByPlatform = Dictionary(grouping: top500, by: \.platform).mapValues(\.count)
        print("--- top-500 (what the inbox loaded) ---")
        for (p, c) in top500ByPlatform.sorted(by: { $0.value > $1.value }) { print("  \(p.rawValue): \(c)") }
        print("platforms visible in top-500:", top500ByPlatform.keys.count)
        print("==================")
    }
}
