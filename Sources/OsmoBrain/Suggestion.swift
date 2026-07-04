import Foundation

/// One of the three labeled takes. The label carries the variation axis (position
/// = meaning), and `whyItWorks` cites the technique so the user learns, not just
/// copies.
public struct SuggestionTake: Equatable, Sendable, Identifiable {
    public enum Slant: String, Codable, Sendable, CaseIterable {
        case direct, warmer, lighter
        public var label: String {
            switch self {
            case .direct: return "The direct one"
            case .warmer: return "The warmer one"
            case .lighter: return "The lighter one"
            }
        }
    }
    public var id: Slant { slant }
    public var slant: Slant
    public var text: String
    /// The lead technique's rationale, shown under the take.
    public var whyItWorks: String?

    public init(slant: Slant, text: String, whyItWorks: String? = nil) {
        self.slant = slant; self.text = text; self.whyItWorks = whyItWorks
    }
}

/// The set of three takes for a moment.
public struct SuggestionSet: Equatable, Sendable {
    public var takes: [SuggestionTake]
    public init(takes: [SuggestionTake]) { self.takes = takes }

    /// Parse model output into three slanted takes. The model is instructed to
    /// return three lines (direct, warmer, lighter) in order; this is tolerant of
    /// numbering, bullets, and blank lines. `why` seeds each take's rationale from
    /// the lead technique.
    public static func parse(_ raw: String, leadWhy: String?) -> SuggestionSet {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { stripLead($0) }
            .filter { !$0.isEmpty }
        let slants: [SuggestionTake.Slant] = [.direct, .warmer, .lighter]
        let takes = lines.prefix(3).enumerated().map { i, text in
            SuggestionTake(slant: slants[i], text: text, whyItWorks: i == 0 ? leadWhy : nil)
        }
        return SuggestionSet(takes: Array(takes))
    }

    /// Strip list markers / numbering / labels / surrounding quotes a model adds.
    static func stripLead(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        // Drop leading "1.", "1)", "-", "•", "*".
        if let r = s.range(of: #"^([0-9]+[.)]|[-•*])\s+"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        // Drop a leading "Direct:" / "Warmer -" style label.
        if let r = s.range(of: #"^(the\s+)?(direct|warmer|lighter)( one)?\s*[:\-–]\s*"#,
                           options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"" + " "))
    }
}
