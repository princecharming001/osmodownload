import Testing
import Foundation
@testable import OsmoBrain

/// This suite is a SAFETY GATE. OccasionDetector feeds the sensitive-gesture
/// tier (condolence/celebration), and the codebase already shipped a
/// "passed" vs "passed away" collision once. The NEGATIVE tests below are the
/// load-bearing ones — they must stay green forever.
@Suite("Occasion detector — sensitive-event detection with collision safety")
struct OccasionDetectorTests {

    func kinds(_ text: String) -> Set<OccasionCandidate.Kind> {
        Set(OccasionDetector.scan(text).map(\.kind))
    }

    // MARK: Positive — real occasions ARE detected

    @Test("'my dad passed away' is a possible loss")
    func lossDetected() {
        let cands = OccasionDetector.scan("hey, my dad passed away last week")
        #expect(cands.contains { $0.kind == .possibleLoss })
    }

    @Test("Loss candidates are always flagged for LLM confirmation, never surfaced raw")
    func lossNeedsConfirmation() {
        let loss = OccasionDetector.scan("we had the funeral yesterday").first { $0.kind == .possibleLoss }
        #expect(loss?.needsLLMConfirmation == true)
        #expect(loss?.isSensitive == true)
    }

    @Test("'got engaged' is a possible celebration, flagged for confirmation")
    func celebrationDetected() {
        let c = OccasionDetector.scan("we got engaged!!").first { $0.kind == .possibleCelebration }
        #expect(c != nil)
        #expect(c?.needsLLMConfirmation == true)
    }

    @Test("Birthdays and anniversaries are factual, not sensitive")
    func factualKinds() {
        #expect(kinds("my birthday is next friday").contains(.birthday))
        #expect(kinds("it's our anniversary tomorrow").contains(.anniversary))
        #expect(kinds("the deadline is monday").contains(.deadline))
        // None of these should be flagged sensitive.
        let bday = OccasionDetector.scan("my birthday is friday").first { $0.kind == .birthday }
        #expect(bday?.isSensitive == false)
    }

    // MARK: NEGATIVE — the collision class must NEVER read as loss

    @Test("'passed the exam' is NOT a loss (the passed/passed-away collision)")
    func passedExamNotLoss() {
        #expect(!kinds("i passed the exam!").contains(.possibleLoss))
    }

    @Test("'passed the bar' is NOT a loss")
    func passedBarNotLoss() {
        #expect(!kinds("she finally passed the bar").contains(.possibleLoss))
    }

    @Test("'dead to me' is NOT a loss")
    func deadToMeNotLoss() {
        #expect(!kinds("honestly he's dead to me now").contains(.possibleLoss))
    }

    @Test("'killed it' is NOT a loss")
    func killedItNotLoss() {
        #expect(!kinds("you killed it in the presentation").contains(.possibleLoss))
    }

    @Test("'dying to see you' is NOT a loss")
    func dyingToNotLoss() {
        #expect(!kinds("i'm dying to see you this weekend").contains(.possibleLoss))
    }

    @Test("'lost my keys' is NOT a loss (bare 'lost' never triggers)")
    func lostKeysNotLoss() {
        #expect(!kinds("ugh i lost my keys again").contains(.possibleLoss))
    }

    @Test("'dead tired' is NOT a loss")
    func deadTiredNotLoss() {
        #expect(!kinds("i'm dead tired today").contains(.possibleLoss))
    }

    @Test("Empty / nil text yields no candidates")
    func emptyText() {
        #expect(OccasionDetector.scan(nil).isEmpty)
        #expect(OccasionDetector.scan("").isEmpty)
        #expect(OccasionDetector.scan("just grabbing lunch").isEmpty)
    }
}
