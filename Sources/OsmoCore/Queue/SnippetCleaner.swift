import Foundation

/// One readable snippet line out of a raw message body — pure string pipeline,
/// no I/O. Flattens control chars/newlines (the same posture as the inbox's
/// `previewLine`), strips the event-platform boilerplate that made queue cards
/// read like calendar exports ("You've got a spot at  Poker Night  Tuesday,
/// July 14 7:00 PM - 11:00 PM PDT  Location:…"), collapses whitespace, and
/// clamps on a word boundary. Normal human texts pass through unchanged.
public enum SnippetCleaner {

    /// Boilerplate kill-list, applied to the flattened single-line text.
    /// Order matters: the leading "you've got a spot at" strip runs first so
    /// the event NAME survives while the date/location debris after it dies.
    private static let killPatterns: [String] = [
        // Leading event-registration framing — keep what follows (the name).
        #"(?i)^you'?ve got a spot at\s+"#,
        // Weekday-month-day-time-range runs: "Tuesday, July 14 7:00 PM - 11:00 PM PDT".
        #"(?i)\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday),?\s+"#
            + #"(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+"#
            + #"\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?"#
            + #"(?:\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)(?:\s*[-–—]\s*\d{1,2}(?::\d{2})?\s*(?:am|pm))?)?"#
            + #"(?:\s+(?:PST|PDT|MST|MDT|CST|CDT|EST|EDT|UTC|GMT))?"#,
        // Venue block through to the end of the (flattened) body.
        #"(?i)\blocation:.*$"#,
        // Newsletter chrome + unsubscribe footers.
        #"(?i)\bview (?:this email )?in (?:your )?browser\b"#,
        #"(?i)\b(?:to )?unsubscribe\b.*$"#,
        #"(?i)\byou(?:'re| are) receiving this (?:email|message)\b.*$"#,
    ]

    public static func clean(_ raw: String, maxLength: Int = 80) -> String {
        // 1. Flatten: newlines and control characters become spaces (mirrors the
        //    inbox preview's posture — never a raw control-char blob).
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // 2. Strip boilerplate.
        var cleaned = flattened
        for pattern in killPatterns {
            guard let regex = try? Regex(pattern) else { continue }
            cleaned = cleaned.replacing(regex, with: " ")
        }

        // 3. Collapse whitespace.
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A body that was PURE boilerplate shouldn't collapse to an empty card —
        // fall back to the flattened original.
        if cleaned.isEmpty {
            cleaned = flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        // 4. Clamp on a word boundary with an ellipsis.
        guard cleaned.count > maxLength else { return cleaned }
        var clipped = String(cleaned.prefix(maxLength))
        if let lastSpace = clipped.lastIndex(where: \.isWhitespace) {
            clipped = String(clipped[..<lastSpace])
        }
        return clipped.trimmingCharacters(in: .whitespaces) + "…"
    }
}
