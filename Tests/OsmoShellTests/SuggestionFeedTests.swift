import Testing
import Foundation
import OsmoCore
@testable import OsmoShell

@Suite("Suggestion feed — brain decisions → ranked, filtered feed rows")
struct SuggestionFeedTests {
    func decision(_ threadID: UUID = UUID(), kind: String, status: StoredDecisionStatus = .fresh,
                  confidence: Double = 0.7, sensitive: Bool = false, move: String? = "do the thing",
                  gestureKind: String? = nil, why: String? = nil) -> StoredDecision {
        StoredDecision(id: "\(threadID.uuidString):h", threadID: threadID, kind: kind, move: move,
                       gestureKind: gestureKind, why: why, confidence: confidence,
                       inputHash: "h", isSensitive: sensitive, status: status,
                       expiresAt: Date().addingTimeInterval(3600))
    }

    @Test("nothing / terminal-status decisions never surface")
    func filtersNoise() {
        let t1 = UUID(), t2 = UUID(), t3 = UUID()
        let feed = SuggestionFeed.build(decisions: [
            decision(t1, kind: "nothing"),
            decision(t2, kind: "reachOut", status: .dismissed),
            decision(t3, kind: "reachOut", status: .expired),
        ], displayNames: [:])
        #expect(feed.isEmpty)
    }

    @Test("a fresh reach-out surfaces with the person's name and move")
    func reachOutSurfaces() {
        let t = UUID()
        let feed = SuggestionFeed.build(decisions: [decision(t, kind: "reachOut", move: "ask about her trip")],
                                        displayNames: [t: "Sarah"])
        #expect(feed.count == 1)
        #expect(feed[0].kind == .reachOut)
        #expect(feed[0].title.contains("Sarah"))
        #expect(feed[0].detail == "ask about her trip")
    }

    @Test("reach-out outranks a hold-back")
    func ranking() {
        let t1 = UUID(), t2 = UUID()
        let feed = SuggestionFeed.build(decisions: [
            decision(t1, kind: "holdBack", why: "give space"),
            decision(t2, kind: "reachOut"),
        ], displayNames: [t1: "A", t2: "B"])
        #expect(feed.first?.kind == .reachOut)
    }

    @Test("one item per thread — the highest-priority wins")
    func onePerThread() {
        let t = UUID()
        let feed = SuggestionFeed.build(decisions: [
            decision(t, kind: "holdBack"),
            decision(t, kind: "reachOut"),
        ], displayNames: [t: "A"])
        #expect(feed.count == 1)
        #expect(feed[0].kind == .reachOut)
    }

    @Test("cap limits the feed length")
    func caps() {
        let decisions = (0..<12).map { _ in decision(UUID(), kind: "reachOut") }
        #expect(SuggestionFeed.build(decisions: decisions, displayNames: [:], cap: 5).count == 5)
    }

    @Test("a condolence gesture carries the sensitive flag and a check-in title")
    func gestureRendering() {
        let t = UUID()
        let feed = SuggestionFeed.build(decisions: [
            decision(t, kind: "gesture", sensitive: true, move: "Did something happen with your dad?",
                     gestureKind: "condolence")
        ], displayNames: [t: "Mia"])
        #expect(feed.count == 1)
        #expect(feed[0].kind == .gesture)
        #expect(feed[0].isSensitive)
        #expect(feed[0].title.contains("Mia"))
        #expect(feed[0].gestureKind == "condolence")
    }

    @Test("a surfaced (already-shown) decision still appears; only terminal ones drop")
    func surfacedStillShows() {
        let t = UUID()
        let feed = SuggestionFeed.build(decisions: [decision(t, kind: "reachOut", status: .surfaced)],
                                        displayNames: [t: "A"])
        #expect(feed.count == 1)
    }
}
