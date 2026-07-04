import Testing
import Foundation
import OsmoCore
@testable import OsmoShell

@Suite("Inbox platform filter")
struct InboxFilterTests {
    func thread(_ platform: Platform, _ pid: String) -> OsmoThread {
        OsmoThread(id: OsmoThread.makeID(platform: platform, platformThreadID: pid),
                   updatedAt: Date(), deviceSeq: 0, platform: platform,
                   platformThreadID: pid, title: nil, isGroup: false)
    }

    @Test("present() returns only platforms that have threads, in canonical order")
    func present() {
        let threads = [thread(.slack, "a"), thread(.imessage, "b"), thread(.imessage, "c")]
        // Canonical Platform.allCases order is imessage, gmail, slack, … → imessage before slack.
        #expect(InboxFilter.present(in: threads) == [.imessage, .slack])
        #expect(InboxFilter.present(in: []) == [])
    }

    @Test("apply(nil) returns everything; apply(platform) returns only that platform")
    func apply() {
        let threads = [thread(.slack, "a"), thread(.imessage, "b"), thread(.linkedin, "c"), thread(.imessage, "d")]
        #expect(InboxFilter.apply(nil, to: threads).count == 4)
        let iMessage = InboxFilter.apply(.imessage, to: threads)
        #expect(iMessage.count == 2)
        #expect(iMessage.allSatisfy { $0.platform == .imessage })
        #expect(InboxFilter.apply(.gmail, to: threads).isEmpty)   // platform with no threads
    }

    @Test("A single-platform inbox yields one chip and filtering is a no-op — the 'looks broken' case")
    func singlePlatform() {
        let threads = [thread(.imessage, "a"), thread(.imessage, "b")]
        #expect(InboxFilter.present(in: threads) == [.imessage])
        // Filtering to the only platform returns the SAME set — nothing visibly changes.
        #expect(InboxFilter.apply(.imessage, to: threads).count == threads.count)
    }
}
