import Foundation
import OsmoCore

/// Persisted day/count for the autodraft daily cap. The app owns where this
/// lives (UserDefaults); this type is just the pure shape + rollover math.
public struct AutodraftCapState: Codable, Equatable, Sendable {
    public var day: String    // "yyyy-MM-dd", local calendar
    public var used: Int
    public init(day: String, used: Int) { self.day = day; self.used = used }
    public static let empty = AutodraftCapState(day: "", used: 0)
}

/// Every guard for "should Osmo autodraft this thread right now" — pure and
/// exhaustively testable, so the app-layer wiring can stay thin.
public enum AutodraftPolicy {
    public static let dailyCap = 30

    public struct Decision: Equatable, Sendable {
        public var go: Bool
        public var newCap: AutodraftCapState
        public var reason: String?
        public init(go: Bool, newCap: AutodraftCapState, reason: String?) {
            self.go = go; self.newCap = newCap; self.reason = reason
        }
    }

    /// `existingDraft` is nil when the thread has no saved draft; otherwise the
    /// current text + whether IT was itself an autodraft (never overwritten) or
    /// user-typed (never touched).
    /// - Parameter heldBack: the relationship brain says to GIVE THIS PERSON SPACE.
    ///   Even a needs-reply thread won't be auto-drafted while held. Defaults to
    ///   false so every existing call site is unchanged; the app only passes true
    ///   behind the relationshipBrain flag.
    public static func decide(enabled: Bool, isPro: Bool, isGroup: Bool, isHuman: Bool,
                              status: TextingStatus, existingDraft: (text: String, isAuto: Bool)?,
                              cap: AutodraftCapState, now: Date, calendar: Calendar = .current,
                              heldBack: Bool = false) -> Decision {
        let todayKey = dayKey(now, calendar: calendar)
        // A cap from a previous day rolls over to zero-used today.
        let freshCap = cap.day == todayKey ? cap : AutodraftCapState(day: todayKey, used: 0)

        func no(_ reason: String) -> Decision { Decision(go: false, newCap: freshCap, reason: reason) }

        guard enabled else { return no("autodraft is off") }
        guard !heldBack else { return no("held back — giving them space") }
        guard isPro else { return no("not Pro") }
        guard !isGroup else { return no("group thread") }
        guard isHuman else { return no("not a human thread") }
        guard status == .needsReply else { return no("not needs-reply") }
        // Never overwrite text the user actually typed.
        if let existing = existingDraft, !existing.text.isEmpty, !existing.isAuto {
            return no("user has an unsent draft")
        }
        guard freshCap.used < dailyCap else { return no("daily cap reached") }

        return Decision(go: true, newCap: AutodraftCapState(day: todayKey, used: freshCap.used + 1), reason: nil)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
