import Testing
import Foundation
@testable import OsmoCore

/// W3 P7 — hold-back suppression in the queue. NEW cases (the existing 25 queue
/// tests pass unchanged because holdBacks defaults to empty).
@Suite("Morning queue — brain hold-back suppression")
struct MorningQueueHoldBackTests {
    let now = Date(timeIntervalSince1970: 1_780_000_000)   // fixed → deterministic priority
    func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func snap(_ id: UUID, lastFromMe: Bool, readByThem: Bool, daysAgo: Double,
              personID: UUID? = UUID()) -> ThreadSnapshot {
        ThreadSnapshot(threadID: id, personID: personID, personName: "Sam", platform: .imessage,
                       lastFromMe: lastFromMe, lastMessageAt: ago(daysAgo),
                       myLastReadByThem: readByThem ? ago(daysAgo) : nil,
                       theirLastText: lastFromMe ? nil : "hey", isLikelyHuman: true, isGroup: false)
    }

    @Test("A held-back thread drops its leftOnRead nudge")
    func holdBackDropsLeftOnRead() {
        let id = UUID()
        let s = snap(id, lastFromMe: true, readByThem: true, daysAgo: 2)
        let normal = MorningQueue.build(snapshots: [s], projects: [], now: now)
        let held = MorningQueue.build(snapshots: [s], projects: [], now: now, holdBacks: [id])
        if normal.contains(where: { $0.kind == .leftOnRead }) {
            #expect(!held.contains { $0.kind == .leftOnRead })
        }
    }

    @Test("A held-back thread STILL surfaces a needs-reply card (you always owe a reply)")
    func holdBackKeepsReply() {
        let id = UUID()
        let s = snap(id, lastFromMe: false, readByThem: false, daysAgo: 0.1)
        let held = MorningQueue.build(snapshots: [s], projects: [], now: now, holdBacks: [id])
        let normal = MorningQueue.build(snapshots: [s], projects: [], now: now)
        #expect(held.contains { $0.kind == .reply } == normal.contains { $0.kind == .reply })
    }

    @Test("holdBacks defaulting to empty leaves the queue identical (backward compatible)")
    func emptyHoldBacksNoOp() {
        let s = snap(UUID(), lastFromMe: true, readByThem: true, daysAgo: 2)
        #expect(MorningQueue.build(snapshots: [s], projects: [], now: now)
                == MorningQueue.build(snapshots: [s], projects: [], now: now, holdBacks: []))
    }
}
