import Foundation
import OsmoCore

/// Pure decision layer for local notifications — "should this inbound message
/// notify, right now?" Keeping the rules here (not in the UNUserNotification
/// plumbing) makes the whole matrix unit-testable.
public enum NotificationRules {

    public struct InboundSignal: Equatable, Sendable {
        public var threadID: UUID
        public var isFromMe: Bool
        public var sentAt: Date
        public init(threadID: UUID, isFromMe: Bool, sentAt: Date) {
            self.threadID = threadID; self.isFromMe = isFromMe; self.sentAt = sentAt
        }
    }

    /// A quiet-hours window by local hour. `start > end` wraps midnight
    /// (e.g. QuietHours(22, 7) = 10pm–7am). Its own type because a wrapping
    /// window can't be a ClosedRange (that traps on lower > upper).
    public struct QuietHours: Equatable, Sendable {
        public var startHour: Int
        public var endHour: Int
        public init(_ startHour: Int, _ endHour: Int) {
            self.startHour = startHour; self.endHour = endHour
        }
        public func contains(_ hour: Int) -> Bool {
            if startHour <= endHour { return hour >= startHour && hour <= endHour }
            return hour >= startHour || hour <= endHour   // wraps midnight
        }
    }

    public struct Environment: Sendable {
        /// Threads the user muted (per-connection pause or per-thread mute).
        public var mutedThreadIDs: Set<UUID>
        /// The thread currently open+focused in the app — never notify for it.
        public var focusedThreadID: UUID?
        /// Threads already notified this coalescing window.
        public var recentlyNotified: Set<UUID>
        /// Quiet-hours window (may wrap midnight).
        public var quietHours: QuietHours?
        public var now: Date
        public var calendar: Calendar

        public init(mutedThreadIDs: Set<UUID> = [], focusedThreadID: UUID? = nil,
                    recentlyNotified: Set<UUID> = [], quietHours: QuietHours? = nil,
                    now: Date = Date(), calendar: Calendar = .current) {
            self.mutedThreadIDs = mutedThreadIDs; self.focusedThreadID = focusedThreadID
            self.recentlyNotified = recentlyNotified; self.quietHours = quietHours
            self.now = now; self.calendar = calendar
        }
    }

    public enum Decision: Equatable, Sendable {
        case notify
        case suppress(reason: String)
    }

    public static func decide(_ signal: InboundSignal, _ env: Environment) -> Decision {
        if signal.isFromMe { return .suppress(reason: "from me") }
        if env.mutedThreadIDs.contains(signal.threadID) { return .suppress(reason: "muted") }
        if env.focusedThreadID == signal.threadID { return .suppress(reason: "thread focused") }
        if env.recentlyNotified.contains(signal.threadID) { return .suppress(reason: "coalesced") }
        if let quiet = env.quietHours {
            let hour = env.calendar.component(.hour, from: env.now)
            if quiet.contains(hour) { return .suppress(reason: "quiet hours") }
        }
        return .notify
    }
}
