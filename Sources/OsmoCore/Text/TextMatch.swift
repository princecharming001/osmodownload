import Foundation

/// Word-boundary keyword matching, shared across classifiers (goals, moves,
/// registers) so "ask" doesn't fire inside "basket".
public enum TextMatch {
    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    public static func word(_ haystack: String, _ needle: String) -> Bool {
        guard let range = haystack.range(of: needle) else { return false }
        let before = range.lowerBound == haystack.startIndex ? nil
            : haystack[haystack.index(before: range.lowerBound)]
        let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
        let beforeOK = before.map { !isWordChar($0) } ?? true
        let afterOK = after.map { !isWordChar($0) } ?? true
        return beforeOK && afterOK
    }
}
