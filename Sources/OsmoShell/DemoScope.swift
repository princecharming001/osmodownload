import Foundation
import OsmoCore

/// Demo mode: a uniformly tiny, analyzable dataset — per platform, the 5 most
/// recently active conversations with activity in the last 15 days. A pure VIEW
/// filter: nothing in the store is touched or deleted, and switching the toggle
/// off restores everything instantly. (The web backfill has a matching server-
/// side scope — OSMO_BACKFILL_SCOPE=demo — so fresh API pulls stay light too.)
public enum DemoScope {
    public static let maxThreadsPerPlatform = 5
    public static let windowDays = 15

    /// Messages older than this are hidden from transcripts while demo mode is on.
    public static func messageCutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(windowDays) * 86_400)
    }

    /// Per platform: only threads active inside the window, newest first, capped.
    public static func trim(_ threads: [OsmoThread], now: Date = Date()) -> [OsmoThread] {
        let cutoff = messageCutoff(now: now)
        let byPlatform = Dictionary(grouping: threads, by: \.platform)
        var out: [OsmoThread] = []
        for (_, group) in byPlatform {
            let recent = group
                .filter { ($0.lastMessageAt ?? .distantPast) >= cutoff }
                .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
            out.append(contentsOf: recent.prefix(maxThreadsPerPlatform))
        }
        return out.sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }
}
