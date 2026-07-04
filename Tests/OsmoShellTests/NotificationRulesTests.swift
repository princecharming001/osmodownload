import Testing
import Foundation
import OsmoCore
@testable import OsmoShell

@Suite("Notification rules matrix")
struct NotificationRulesTests {
    let thread = UUID()
    func signal(fromMe: Bool = false) -> NotificationRules.InboundSignal {
        .init(threadID: thread, isFromMe: fromMe, sentAt: Date())
    }

    @Test("A fresh inbound from someone else notifies")
    func basicNotify() {
        #expect(NotificationRules.decide(signal(), .init()) == .notify)
    }

    @Test("From-me / muted / focused / coalesced all suppress")
    func suppressions() {
        #expect(NotificationRules.decide(signal(fromMe: true), .init()) == .suppress(reason: "from me"))
        #expect(NotificationRules.decide(signal(), .init(mutedThreadIDs: [thread])) == .suppress(reason: "muted"))
        #expect(NotificationRules.decide(signal(), .init(focusedThreadID: thread)) == .suppress(reason: "thread focused"))
        #expect(NotificationRules.decide(signal(), .init(recentlyNotified: [thread])) == .suppress(reason: "coalesced"))
    }

    @Test("Quiet hours suppress, including windows that wrap midnight")
    func quietHours() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: hour))!
        }
        // Non-wrapping 9–17: 11am suppressed, 20:00 allowed.
        #expect(NotificationRules.decide(signal(), .init(quietHours: .init(9, 17), now: at(11), calendar: cal)) == .suppress(reason: "quiet hours"))
        #expect(NotificationRules.decide(signal(), .init(quietHours: .init(9, 17), now: at(20), calendar: cal)) == .notify)
        // Wrapping 22–7: 2am suppressed, 12pm allowed.
        #expect(NotificationRules.decide(signal(), .init(quietHours: .init(22, 7), now: at(2), calendar: cal)) == .suppress(reason: "quiet hours"))
        #expect(NotificationRules.decide(signal(), .init(quietHours: .init(22, 7), now: at(12), calendar: cal)) == .notify)
    }

    @Test("QuietHours.contains boundary logic incl. midnight wrap")
    func boundaryHelper() {
        #expect(NotificationRules.QuietHours(9, 17).contains(9))
        #expect(NotificationRules.QuietHours(9, 17).contains(17))
        #expect(!NotificationRules.QuietHours(9, 17).contains(8))
        #expect(NotificationRules.QuietHours(22, 7).contains(23))
        #expect(NotificationRules.QuietHours(22, 7).contains(3))
        #expect(!NotificationRules.QuietHours(22, 7).contains(12))
    }
}
