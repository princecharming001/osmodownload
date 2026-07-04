import Testing
import Foundation
@testable import OsmoBrain

@Suite("Voice profile — sound like the user")
struct VoiceProfileTests {
    func turn(_ fromMe: Bool, _ text: String) -> ThreadTurn { ThreadTurn(fromMe: fromMe, text: text) }

    @Test("Too few of the user's own messages → no profile (don't guess)")
    func tooFew() {
        #expect(VoiceProfile.read([turn(false, "hey there"), turn(true, "hi")]).isEmpty)
    }

    @Test("Lowercase, no-emoji, terse texter is captured")
    func lowercaseTerse() {
        let turns = [
            turn(true, "yeah that works for me"),
            turn(false, "Great, see you then!"),
            turn(true, "cool see you"),
            turn(true, "running like 5 late"),
        ]
        let lines = VoiceProfile.read(turns).joined(separator: " | ")
        #expect(lines.lowercased().contains("lowercase"))
        #expect(lines.lowercased().contains("terse") || lines.contains("word"))
        // The other person's "Great!" must NOT make it think the user uses exclamations.
        #expect(lines.lowercased().contains("exclamation") || !lines.contains("!"))
    }

    @Test("Emoji-heavy user gets the emoji-ok directive")
    func emojiUser() {
        let turns = [
            turn(true, "omg yes 😂 so good"),
            turn(true, "cant wait 🥳🥳"),
            turn(true, "love that idea ❤️"),
        ]
        let lines = VoiceProfile.read(turns).joined(separator: " | ").lowercased()
        #expect(lines.contains("emoji"))
    }
}
