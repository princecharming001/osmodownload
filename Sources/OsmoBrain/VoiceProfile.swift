import Foundation

/// A read of how the USER themselves texts, taken from their own outgoing turns.
/// The draft has to sound like the user, so we profile their real habits — length,
/// casing, emoji, punctuation, sign-offs — and hand the model concrete directives.
/// Pure + testable; empty when there aren't enough of the user's messages to judge.
public enum VoiceProfile {
    public static func read(_ turns: [ThreadTurn]) -> [String] {
        // The user's own recent messages (skip 1-word "ok"/"lol" acks — they don't
        // characterize voice).
        let mine = turns.filter { $0.fromMe }.suffix(40)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(separator: " ").count >= 2 }
        guard mine.count >= 3 else { return [] }

        var lines: [String] = []

        // Length.
        let avgWords = mine.map { $0.split(separator: " ").count }.reduce(0, +) / mine.count
        if avgWords <= 6 { lines.append("You text in short bursts (~\(max(avgWords,1)) words) — keep drafts terse.") }
        else if avgWords <= 14 { lines.append("Your messages run ~\(avgWords) words — a sentence or two.") }
        else { lines.append("You write fuller messages (~\(avgWords) words) — but never padded.") }

        // Casing.
        let lettered = mine.filter { $0.contains(where: \.isLetter) }
        let lowercaseShare = Double(lettered.filter { $0 == $0.lowercased() }.count) / Double(max(lettered.count, 1))
        if lowercaseShare > 0.6 { lines.append("You mostly text in lowercase — do that.") }

        // Emoji.
        let emojiShare = Double(mine.filter { containsEmoji($0) }.count) / Double(mine.count)
        if emojiShare > 0.4 { lines.append("You use emoji naturally — one that fits is on-voice.") }
        else if emojiShare < 0.05 { lines.append("You almost never use emoji — don't add them.") }

        // End punctuation / periods.
        let endsWithPeriod = Double(mine.filter { $0.hasSuffix(".") }.count) / Double(mine.count)
        if endsWithPeriod < 0.15 { lines.append("You usually skip the ending period — leave it off.") }

        // Exclamation habit.
        let exclaimShare = Double(mine.filter { $0.contains("!") }.count) / Double(mine.count)
        if exclaimShare < 0.05 { lines.append("You rarely use exclamation points — keep it flat.") }

        return lines
    }

    private static func containsEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }
}
