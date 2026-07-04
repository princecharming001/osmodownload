import Foundation

/// Apple stores Messages timestamps as an offset from the **Cocoa epoch**
/// (2001-01-01 UTC), in **nanoseconds** since macOS High Sierra (seconds on
/// older databases). Zero means "no value" (e.g. an unread message's
/// `date_read`). This converts a raw chat.db timestamp to a `Date`.
public enum AppleTime {
    /// Seconds between the Unix epoch (1970) and the Cocoa epoch (2001).
    public static let cocoaEpochOffset: TimeInterval = 978_307_200

    public static func date(fromRaw raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        // Heuristic: nanosecond values are astronomically large (~6e17 in 2026);
        // a plain-seconds value is ~8e8. Split well above any real seconds value.
        let seconds: TimeInterval = raw > 1_000_000_000_000
            ? Double(raw) / 1_000_000_000
            : Double(raw)
        return Date(timeIntervalSince1970: seconds + cocoaEpochOffset)
    }
}
