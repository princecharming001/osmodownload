import Foundation
import OsmoCore

/// Deterministic, instant-for-every-thread half of the inbox's Action/Time
/// layers. No LLM, no I/O — the same house style as HumanThreadClassifier. The
/// LLM pass (OsmoBrain.ThreadIntel) fills in what these regexes can't (Emotion,
/// nuanced Action, commitments); when both are present the LLM wins and this
/// fills the gaps.

/// Finds a concrete deadline phrase in a message and resolves it to a real
/// `Date`, relative to `now`.
public enum DeadlineDetector {
    public struct Hit: Equatable, Sendable {
        public var phrase: String
        public var due: Date?
        public init(phrase: String, due: Date?) { self.phrase = phrase; self.due = due }
    }

    private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// Checked in order of confidence; the first match wins.
    public static func detect(_ text: String, now: Date, calendar: Calendar = .current) -> Hit? {
        let lower = text.lowercased()

        if lower.contains("tonight") {
            return Hit(phrase: "tonight", due: calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now))
        }
        if lower.contains("this weekend") {
            return Hit(phrase: "this weekend", due: nextWeekday(7, from: now, calendar: calendar, hour: 10))
        }
        if lower.contains("tomorrow") {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return Hit(phrase: "tomorrow", due: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow))
        }
        for (index, weekday) in weekdayNames.enumerated() {
            if lower.contains("by \(weekday)") {
                // Calendar weekday component: 1 = Sunday … 7 = Saturday.
                return Hit(phrase: "by \(weekday)", due: nextWeekday(index + 1, from: now, calendar: calendar, hour: 17))
            }
        }
        if let hit = detectClockTime(lower, now: now, calendar: calendar) { return hit }
        if let hit = detectExplicitDate(lower, now: now, calendar: calendar) { return hit }
        return nil
    }

    /// "at 5pm", "at 5:30 pm", "at 9am".
    private static func detectClockTime(_ lower: String, now: Date, calendar: Calendar) -> Hit? {
        guard let pattern = try? Regex(#"at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#),
              let match = lower.firstMatch(of: pattern) else { return nil }
        guard let hourStr = match.output[1].substring, var hour = Int(hourStr) else { return nil }
        let minute = match.output[2].substring.flatMap { Int($0) } ?? 0
        let meridiem = match.output[3].substring.map(String.init) ?? ""
        if meridiem == "pm" && hour != 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }
        var due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
        if let d = due, d < now { due = calendar.date(byAdding: .day, value: 1, to: d) }
        return Hit(phrase: String(lower[match.range]), due: due)
    }

    /// "7/9" or "7/9/26" — bare dates assume this year, rolling to next year if
    /// that date already passed.
    private static func detectExplicitDate(_ lower: String, now: Date, calendar: Calendar) -> Hit? {
        guard let pattern = try? Regex(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#),
              let match = lower.firstMatch(of: pattern) else { return nil }
        guard let month = match.output[1].substring.flatMap({ Int($0) }),
              let day = match.output[2].substring.flatMap({ Int($0) }),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var comps = calendar.dateComponents([.year], from: now)
        comps.month = month; comps.day = day; comps.hour = 17; comps.minute = 0
        let explicitYear = match.output[3].substring.flatMap { Int($0) }
        if let y = explicitYear { comps.year = y < 100 ? 2000 + y : y }
        guard var due = calendar.date(from: comps) else { return nil }
        if explicitYear == nil, due < now {
            comps.year = (comps.year ?? 0) + 1
            due = calendar.date(from: comps) ?? due
        }
        return Hit(phrase: String(lower[match.range]), due: due)
    }

    /// The next occurrence of `weekdayComponent` (1=Sunday…7=Saturday) at `hour`,
    /// strictly after `now`.
    private static func nextWeekday(_ weekdayComponent: Int, from now: Date, calendar: Calendar, hour: Int) -> Date? {
        var comps = DateComponents()
        comps.weekday = weekdayComponent
        comps.hour = hour; comps.minute = 0
        return calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTimePreservingSmallerComponents)
    }
}

/// Money mentions — Venmo/Zelle/rent-split talk, or a bare dollar amount.
public enum MoneyDetector {
    private static let markers = [
        "venmo", "zelle", "paypal", "owe", "owes", "rent", "split the bill",
        "splitting the bill", "split it",
    ]

    public static func detect(_ text: String) -> String? {
        let lower = text.lowercased()
        if let pattern = try? Regex(#"\$\d[\d,]*(?:\.\d{2})?"#),
           let match = lower.firstMatch(of: pattern) {
            return String(lower[match.range])
        }
        return markers.first { lower.contains($0) }
    }
}

/// The deterministic half of a thread's intel — instant, free, computed for
/// every thread on every reload.
public struct DeterministicIntel: Equatable, Sendable {
    public var urgency: IntelUrgency?
    public var urgencyReason: String?
    public var action: IntelAction?
    public var openQuestion: Bool
    public var effort: IntelEffort?
    public var deadline: Date?
    public var moneyMention: String?

    public init(urgency: IntelUrgency? = nil, urgencyReason: String? = nil, action: IntelAction? = nil,
                openQuestion: Bool = false, effort: IntelEffort? = nil, deadline: Date? = nil,
                moneyMention: String? = nil) {
        self.urgency = urgency; self.urgencyReason = urgencyReason; self.action = action
        self.openQuestion = openQuestion; self.effort = effort; self.deadline = deadline
        self.moneyMention = moneyMention
    }
}

public enum ThreadSignals {
    /// `theirLastText`/`lastFromMe` match `ThreadSnapshot` exactly — the app
    /// calls this directly with snapshot fields, no adaptation needed.
    public static func read(theirLastText: String?, lastFromMe: Bool,
                            lastMessageAt: Date?, now: Date = Date()) -> DeterministicIntel {
        // The last message was OURS — nothing is waiting on the user right now.
        guard let text = theirLastText, !lastFromMe else { return DeterministicIntel() }

        let openQuestion = text.contains("?")
        let money = MoneyDetector.detect(text)
        let deadlineHit = DeadlineDetector.detect(text, now: now)

        var urgency: IntelUrgency?
        var urgencyReason: String?
        if let due = deadlineHit?.due {
            let interval = due.timeIntervalSince(now)
            if interval < 0 { urgency = .overdue; urgencyReason = "was due \(deadlineHit!.phrase)" }
            else if interval < 86_400 { urgency = .today; urgencyReason = "due \(deadlineHit!.phrase)" }
            else if interval < 3 * 86_400 { urgency = .soon; urgencyReason = "due \(deadlineHit!.phrase)" }
        }

        var action: IntelAction = .reply
        if money != nil { action = .pay }
        else if deadlineHit != nil { action = .schedule }

        let wordCount = text.split(separator: " ").count
        let questionCount = text.filter { $0 == "?" }.count
        let effort: IntelEffort = (wordCount >= 30 || questionCount >= 2 || money != nil || deadlineHit != nil)
            ? .thoughtful : .quick

        return DeterministicIntel(urgency: urgency, urgencyReason: urgencyReason, action: action,
                                  openQuestion: openQuestion, effort: effort,
                                  deadline: deadlineHit?.due, moneyMention: money)
    }
}
