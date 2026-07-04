import Testing
import Foundation
@testable import OsmoCore

@Suite("TextingStatus + MorningQueue (O4)")
struct MorningQueueTests {

    private let now = Date(timeIntervalSince1970: 10_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func snap(_ name: String, person: UUID? = UUID(), fromMe: Bool,
                      idle: TimeInterval, readByThem: TimeInterval? = nil,
                      empty: Bool = false) -> ThreadSnapshot {
        ThreadSnapshot(threadID: UUID(), personID: person, personName: name,
                       platform: .imessage, isEmpty: empty, lastFromMe: fromMe,
                       lastMessageAt: ago(idle),
                       myLastReadByThem: readByThem.map(ago),
                       theirLastText: fromMe ? nil : "hey")
    }

    // MARK: TextingStatus

    @Test("Their message last → needs reply")
    func needsReply() {
        #expect(TextingStatus.derive(snap("Sarah", fromMe: false, idle: 600), now: now) == .needsReply)
    }

    @Test("Left on read is a FACT from the read receipt")
    func leftOnRead() {
        // My message, read 5h ago, no reply → left on read.
        let s = snap("Sarah", fromMe: true, idle: 5 * 3600, readByThem: 5 * 3600)
        #expect(TextingStatus.derive(s, now: now) == .leftOnRead)
        // My message, NOT read yet → just waiting.
        let s2 = snap("Sarah", fromMe: true, idle: 5 * 3600, readByThem: nil)
        #expect(TextingStatus.derive(s2, now: now) == .waiting)
    }

    @Test("Long silence → ghosted; very long → quiet; empty → say hi")
    func silence() {
        #expect(TextingStatus.derive(snap("A", fromMe: true, idle: 5 * 86_400), now: now) == .ghosted)
        #expect(TextingStatus.derive(snap("A", fromMe: true, idle: 40 * 86_400), now: now) == .quiet)
        #expect(TextingStatus.derive(snap("A", fromMe: true, idle: 0, empty: true), now: now) == .sayHi)
    }

    // MARK: MorningQueue

    @Test("Reply-owed people top the queue; a project boosts them")
    func replyTops() {
        let boss = UUID()
        let snaps = [
            snap("Random Person", person: UUID(), fromMe: false, idle: 3600),
            snap("My Boss", person: boss, fromMe: false, idle: 7200)
        ]
        let projects = [Project(personID: boss, title: "Raise", goalText: "ask for a raise")]
        let q = MorningQueue.build(snapshots: snaps, projects: projects, now: now)
        #expect(q.count == 2)
        #expect(q.first?.personName == "My Boss")           // project-boosted reply wins
        #expect(q.allSatisfy { $0.kind == .reply })
    }

    @Test("Quiet thread with no project is NOT surfaced (no clutter)")
    func noProjectNoClutter() {
        let snaps = [snap("Acquaintance", person: UUID(), fromMe: true, idle: 30 * 86_400)]
        #expect(MorningQueue.build(snapshots: snaps, projects: [], now: now).isEmpty)
    }

    @Test("An active goal project surfaces a goal-nudge when the thread stalls")
    func goalNudge() {
        let client = UUID()
        // My message sent 2 days ago, no project reply → goal is stalling.
        let snaps = [snap("Acme Client", person: client, fromMe: true, idle: 2 * 86_400)]
        let projects = [Project(personID: client, title: "Deal", goalText: "close the Acme deal")]
        let q = MorningQueue.build(snapshots: snaps, projects: projects, now: now)
        #expect(q.count == 1)
        #expect(q.first?.kind == .goalNudge)
        #expect(q.first?.projectID == projects[0].id)
        #expect(q.first?.suggestedMove.contains("close the Acme deal") == true)
    }

    @Test("A reconnect project nudges only after the cadence window")
    func reconnect() {
        let friend = UUID()
        let projects = [Project(personID: friend, title: "Stay close", goalText: "reconnect, been forever")]
        // 12 days idle > 10-day cadence → nudge.
        let far = MorningQueue.build(snapshots: [snap("Old Friend", person: friend, fromMe: true, idle: 12 * 86_400)],
                                     projects: projects, now: now)
        #expect(far.first?.kind == .reconnect)
        // 3 days idle < cadence → nothing.
        let near = MorningQueue.build(snapshots: [snap("Old Friend", person: friend, fromMe: true, idle: 3 * 86_400)],
                                      projects: projects, now: now)
        #expect(near.isEmpty)
    }

    @Test("Queue is capped and sorted by priority")
    func cappedSorted() {
        let snaps = (0..<20).map { snap("P\($0)", person: UUID(), fromMe: false, idle: Double($0) * 100) }
        let q = MorningQueue.build(snapshots: snaps, projects: [], now: now,
                                   config: .init(cap: 5))
        #expect(q.count == 5)
        #expect(q == q.sorted { $0.priority > $1.priority })
    }
}
