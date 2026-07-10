import Testing
import Foundation
@testable import OsmoCore

/// The full TextingStatus matrix (lastFromMe x read/unread x age bucket), queue
/// ordering totality/stability, snooze semantics, and SnippetCleaner properties
/// over a hostile corpus.
@Suite("Queue correctness — status matrix, stable ordering, snippet properties")
struct QueueMatrixTests {

    private let now = Date(timeIntervalSince1970: 20_000_000)
    private let config = TextingStatus.Config()   // 3h leftOnRead, 3d ghosted, 21d quiet
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    private func snap(fromMe: Bool, idle: TimeInterval?, readAgo: TimeInterval? = nil,
                      empty: Bool = false, thread: UUID = UUID(), person: UUID? = UUID(),
                      name: String = "Pat") -> ThreadSnapshot {
        ThreadSnapshot(threadID: thread, personID: person, personName: name,
                       platform: .imessage, isEmpty: empty, lastFromMe: fromMe,
                       lastMessageAt: idle.map(ago), myLastReadByThem: readAgo.map(ago),
                       theirLastText: fromMe ? nil : "hey")
    }

    // MARK: - TextingStatus.derive matrix

    @Test("full derive matrix: lastFromMe x read/unread x age buckets")
    func deriveMatrix() {
        let h = 3600.0, d = 86_400.0

        // Empty always wins.
        #expect(TextingStatus.derive(snap(fromMe: true, idle: nil, empty: true), now: now, config: config) == .sayHi)
        #expect(TextingStatus.derive(snap(fromMe: false, idle: 100 * d, empty: true), now: now, config: config) == .sayHi)

        // Their message last → needsReply at EVERY age (an owed reply never ages out).
        for idle in [0.0, 1 * h, 5 * h, 4 * d, 30 * d] {
            #expect(TextingStatus.derive(snap(fromMe: false, idle: idle), now: now, config: config) == .needsReply,
                    "needsReply at idle \(idle)")
        }
        // …and regardless of any read receipt on my older message.
        #expect(TextingStatus.derive(snap(fromMe: false, idle: 2 * d, readAgo: 2 * d), now: now, config: config) == .needsReply)

        // My message last, unread: waiting → ghosted → quiet by age.
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 1 * h), now: now, config: config) == .waiting)
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 2.9 * d), now: now, config: config) == .waiting)
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 3.1 * d), now: now, config: config) == .ghosted)
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 20 * d), now: now, config: config) == .ghosted)
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 22 * d), now: now, config: config) == .quiet)

        // My message last, read: leftOnRead only past the grace window…
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 2 * h, readAgo: 1 * h), now: now, config: config) == .waiting)
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 5 * h, readAgo: 4 * h), now: now, config: config) == .leftOnRead)
        // …and the long-silence buckets take precedence over the receipt.
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 4 * d, readAgo: 4 * d), now: now, config: config) == .ghosted)
        #expect(TextingStatus.derive(snap(fromMe: true, idle: 30 * d, readAgo: 30 * d), now: now, config: config) == .quiet)

        // No timestamp at all (idle 0) behaves like a fresh thread, never crashes.
        #expect(TextingStatus.derive(snap(fromMe: true, idle: nil), now: now, config: config) == .waiting)
        // A clock-skewed FUTURE message (negative idle) stays in the calm bucket.
        #expect(TextingStatus.derive(snap(fromMe: true, idle: -3600), now: now, config: config) == .waiting)
        #expect(TextingStatus.derive(snap(fromMe: false, idle: -3600), now: now, config: config) == .needsReply)
    }

    // MARK: - MorningQueue ordering

    @Test("priority order is total and stable: identical input → identical queue, any input order")
    func stableOrdering() {
        // Ten equal-priority needsReply cards (same idle) + a couple of distinct
        // tiers. Equal priorities must tie-break deterministically (threadID), so
        // the queue can never flap between reloads — even when the caller hands
        // the snapshots over in a different order.
        let equalTier = (0..<10).map { i in
            snap(fromMe: false, idle: 3600, thread: UUID(), name: "Person \(i)")
        }
        let older = snap(fromMe: false, idle: 9 * 86_400, name: "Old Owed")   // lower recency
        let all = equalTier + [older]

        let q1 = MorningQueue.build(snapshots: all, projects: [], now: now)
        let q2 = MorningQueue.build(snapshots: all.reversed(), projects: [], now: now)
        let q3 = MorningQueue.build(snapshots: all.shuffled(), projects: [], now: now)
        #expect(q1.map(\.threadID) == q2.map(\.threadID))
        #expect(q1.map(\.threadID) == q3.map(\.threadID))
        // Total: strictly by priority, ties strictly by threadID.
        for (a, b) in zip(q1, q1.dropFirst()) {
            #expect(a.priority > b.priority
                    || (a.priority == b.priority && a.threadID.uuidString < b.threadID.uuidString))
        }
        // The fresher tier outranks the older owed reply.
        #expect(q1.last?.personName == "Old Owed")
    }

    @Test("cap keeps the TOP priorities, deterministically across shuffles")
    func capIsDeterministic() {
        let snaps = (0..<30).map { i in
            snap(fromMe: false, idle: 3600, thread: UUID(), name: "P\(i)")
        }
        let cfg = MorningQueue.Config(cap: 5)
        let a = MorningQueue.build(snapshots: snaps, projects: [], now: now, config: cfg)
        let b = MorningQueue.build(snapshots: snaps.shuffled(), projects: [], now: now, config: cfg)
        #expect(a.count == 5)
        #expect(a.map(\.threadID) == b.map(\.threadID))   // no flap across the cap boundary
    }

    // MARK: - Snoozes (the queue's exclusion input)

    @Test("snoozedThreadIDs with an ELAPSED snooze still present: auto-clears, does not throw")
    func elapsedSnoozeAutoClears() throws {
        // Regression: the auto-clear DELETE used to run inside dbQueue.read —
        // GRDB read blocks are read-only, so the first elapsed snooze made this
        // call throw SQLITE_READONLY (the existing test cleared via dueSnoozes()
        // first and never hit it).
        let store = try OsmoStore.inMemory()
        let t = OsmoThread(id: OsmoThread.makeID(platform: .imessage, platformThreadID: "c1"),
                           updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                           platform: .imessage, platformThreadID: "c1", title: nil, isGroup: false)
        try store.ingest(t)
        let live = OsmoThread(id: OsmoThread.makeID(platform: .imessage, platformThreadID: "c2"),
                              updatedAt: Date(timeIntervalSince1970: 0), deviceSeq: 0,
                              platform: .imessage, platformThreadID: "c2", title: nil, isGroup: false)
        try store.ingest(live)

        try store.snooze(thread: t.id, until: Date(timeIntervalSinceNow: -60))   // elapsed
        try store.snooze(thread: live.id, until: Date(timeIntervalSinceNow: 3600))

        let snoozed = try store.snoozedThreadIDs()      // must not throw
        #expect(!snoozed.contains(t.id))                // elapsed → hidden no more
        #expect(snoozed.contains(live.id))              // future → still hidden
        // The elapsed one was cleared, so it no longer surfaces as "due" either.
        #expect(try store.dueSnoozes().isEmpty)
    }

    // MARK: - SnippetCleaner properties

    @Test("property: non-empty when input has letters, bounded, no edge whitespace — over a hostile corpus")
    func snippetProperties() {
        let corpus: [String] = [
            "hey are we still on for tonight?",
            "مرحبا كيف حالك اليوم؟ أتمنى أن تكون بخير",                  // RTL Arabic
            "שלום! מה נשמע? \u{200F}עם סימון כיווניות",                  // RTL + RLM
            "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦",                                             // ZWJ family emoji only
            "🎉🎉🎉",                                                     // emoji only
            "",                                                          // empty
            "   \n\t  ",                                                 // whitespace only
            "\u{0007}\u{0000}ding\u{0008}",                              // control chars around letters
            String(repeating: "supercalifragilistic", count: 50),        // one huge token
            String(repeating: "word ", count: 500),                      // many tokens
            "line1\nline2\r\nline3\rline4",
            "a", " a ", "a\u{200D}b",                                    // tiny + zero-width joiner
            "Ünïcödé wïth äccents ünd Späces",
            "普通话的消息，还有一些标点。。。",
            "🇯🇵🇰🇷🇩🇪 flags and ราชอาณาจักรไทย text",
            "Location: my place, come around back",                     // human text that LOOKS like boilerplate
            "You've got a spot at  Poker Night  Tuesday, July 14 7:00 PM - 11:00 PM PDT  Location: 500 Main",
            "To unsubscribe click here. But first: dinner?",
            String(repeating: "🙃", count: 300),
            "\u{202E}reversed-mark text\u{202C} normal after",           // BiDi override chars
        ]
        for maxLength in [10, 40, 80] {
            for raw in corpus {
                for aggressive in [false, true] {
                    let out = SnippetCleaner.clean(raw, maxLength: maxLength, stripBoilerplate: aggressive)
                    let label = "input \(String(raw.prefix(24)).debugDescription) max \(maxLength) strip \(aggressive)"
                    #expect(out.count <= maxLength + 1, "too long — \(label) → \(out.count)")
                    if raw.contains(where: \.isLetter) {
                        #expect(!out.isEmpty, "empty despite letters — \(label)")
                    }
                    if let first = out.first { #expect(!first.isWhitespace, "leading space — \(label)") }
                    if let last = out.last { #expect(!last.isWhitespace, "trailing space — \(label)") }
                    // Flattening contract: never a raw newline/control char in a snippet.
                    #expect(!out.contains(where: { $0 == "\n" || $0 == "\r" }), "newline survived — \(label)")
                }
            }
        }
    }
}
