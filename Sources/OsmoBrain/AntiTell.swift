import Foundation

/// The rules that keep a draft reading like a real human text, not an AI. Injected
/// into the stable psychology core (so they're prompt-cached), hardened with the
/// concrete tells that leak: em-dashes, assistant openers, question mirroring,
/// exclamation stacking, spelled-out contractions, corporate filler words.
public enum AntiTell {
    public static let rules: [String] = [
        "Never use em-dashes (—). Use a comma, a period, or start a new line.",
        "Never use AI filler: delve, leverage, seamless, robust, tapestry, testament, underscore, utilize, furthermore, moreover, elevate, showcase, that said, at the end of the day.",
        "No assistant openers: never \"I hope you're doing well\", \"Just checking in!\", \"I wanted to reach out\", \"I just wanted to\".",
        "Always use contractions (I'm, don't, can't, you're). Spelled-out forms read stiff in a text.",
        "At most one exclamation mark in the whole message, and only if their energy warrants it.",
        "Don't mirror their question back at them as your reply.",
        "No quotation marks around the message, no preamble, no sign-off they wouldn't actually use.",
        "Vary sentence length; don't average everything to medium. Write the length a human would actually thumb-type.",
        "Match their capitalization and punctuation habits — if they text lowercase with no periods, so do you."
    ]

    public static var block: String {
        "Make it read like a real human text, never like an AI:\n" +
            rules.map { "- \($0)" }.joined(separator: "\n")
    }
}
