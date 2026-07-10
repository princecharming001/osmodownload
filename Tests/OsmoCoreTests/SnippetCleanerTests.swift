import Testing
import Foundation
@testable import OsmoCore

@Suite("SnippetCleaner — one readable queue line out of a raw body")
struct SnippetCleanerTests {

    @Test("The real Poker Night artifact reduces to the event name (aggressive path)")
    func pokerNightArtifact() {
        let raw = "You've got a spot at  Poker Night  Tuesday, July 14 7:00 PM - 11:00 PM PDT  Location:..."
        #expect(SnippetCleaner.clean(raw, stripBoilerplate: true) == "Poker Night")
    }

    @Test("Normal human texts pass through unchanged")
    func humanTextsUntouched() {
        #expect(SnippetCleaner.clean("your package arrived lol") == "your package arrived lol")
        #expect(SnippetCleaner.clean("dinner at 7? i'm starving") == "dinner at 7? i'm starving")
        #expect(SnippetCleaner.clean("ok see you then") == "ok see you then")
    }

    @Test("The default path never mangles a human message that LOOKS like boilerplate")
    func humanBoilerplateLookalikesSurvive() {
        // A friend's directions must not be truncated by the "Location:" kill
        // pattern — boilerplate stripping is opt-in for automated content only.
        let directions = "Location: my place, come around back"
        #expect(SnippetCleaner.clean(directions) == directions)
        let plans = "party is Saturday, June 6 8:00 PM btw"
        #expect(SnippetCleaner.clean(plans) == plans)
    }

    @Test("Newlines and control characters flatten to single spaces")
    func flattensControlChars() {
        #expect(SnippetCleaner.clean("line one\nline two\r\nline three") == "line one line two line three")
        #expect(SnippetCleaner.clean("odd\u{0B}payload\u{0C}here") == "odd payload here")
    }

    @Test("Newsletter chrome and unsubscribe footers die (aggressive path)")
    func stripsNewsletterChrome() {
        #expect(SnippetCleaner.clean("Big summer update View in browser", stripBoilerplate: true)
                == "Big summer update")
        #expect(SnippetCleaner.clean("Sale ends Sunday. Unsubscribe from these emails at any time.",
                                     stripBoilerplate: true)
                == "Sale ends Sunday.")
        #expect(SnippetCleaner.clean("New features shipped. You are receiving this email because you signed up.",
                                     stripBoilerplate: true)
                == "New features shipped.")
    }

    @Test("Weekday-date-time-range runs are stripped mid-sentence too (aggressive path)")
    func stripsDateRuns() {
        let raw = "Reminder: Standup Wednesday, August 5 9:00 AM - 9:30 AM EST bring updates"
        #expect(SnippetCleaner.clean(raw, stripBoilerplate: true) == "Reminder: Standup bring updates")
    }

    @Test("Long text clamps on a word boundary with an ellipsis")
    func clampsOnWordBoundary() {
        let raw = Array(repeating: "word", count: 40).joined(separator: " ")
        let out = SnippetCleaner.clean(raw, maxLength: 80)
        #expect(out.hasSuffix("…"))
        #expect(out.count <= 81)
        #expect(!out.contains("wor…"))   // never mid-word
    }

    @Test("Pure boilerplate falls back to the flattened original — never an empty card")
    func neverEmpty() {
        let raw = "Location: 123 Main St"
        #expect(SnippetCleaner.clean(raw, stripBoilerplate: true) == "Location: 123 Main St")
    }
}
