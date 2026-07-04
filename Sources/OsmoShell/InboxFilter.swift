import Foundation
import OsmoCore

/// Pure inbox-filter logic, hoisted out of the view so it's unit-tested and the
/// view can't accidentally break it. `present` gives the chips to show (only
/// platforms that actually have threads); `apply` filters the list.
public enum InboxFilter {
    /// Platforms that have at least one thread, in canonical order.
    public static func present(in threads: [OsmoThread]) -> [Platform] {
        let have = Set(threads.map(\.platform))
        return Platform.allCases.filter { have.contains($0) }
    }

    /// Threads matching the selected platform (nil = all).
    public static func apply(_ filter: Platform?, to threads: [OsmoThread]) -> [OsmoThread] {
        guard let filter else { return threads }
        return threads.filter { $0.platform == filter }
    }
}
