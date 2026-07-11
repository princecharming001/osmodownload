import Foundation

/// Small deterministic statistics shared by the relationship-context layers.
/// Matches the house median idiom already in the codebase
/// (`PartnerProfile.medianReplyGap`): sort + nearest-rank index, and always
/// `nil` below a sample floor rather than returning a meaningless number on a
/// two-message thread. Percentiles use the same nearest-rank convention so
/// p25/median/p75 stay mutually consistent (p50 == median).
enum Stats {
    /// Nearest-rank percentile (q in 0...1) over the values. `nil` when there
    /// are fewer than `minCount` samples — the honesty bar. Nearest-rank means
    /// no interpolation: for n values sorted ascending, rank = ceil(q*n)
    /// clamped to 1...n, returning the value at that 1-based rank.
    static func percentile(_ values: [Double], _ q: Double, minCount: Int = 3) -> Double? {
        guard values.count >= max(1, minCount) else { return nil }
        let sorted = values.sorted()
        let clampedQ = max(0, min(1, q))
        // 1-based nearest rank; q==0 maps to the first element.
        let rank = clampedQ <= 0 ? 1 : Int((clampedQ * Double(sorted.count)).rounded(.up))
        let idx = max(1, min(sorted.count, rank)) - 1
        return sorted[idx]
    }

    static func median(_ values: [Double], minCount: Int = 3) -> Double? {
        percentile(values, 0.5, minCount: minCount)
    }

    /// Population variance. `nil` below the floor — variance on 1-2 points is
    /// noise, and it's exactly the infrequent repliers (small N) where a naive
    /// variance would most mislead.
    static func variance(_ values: [Double], minCount: Int = 3) -> Double? {
        guard values.count >= max(2, minCount) else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let sq = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sq / Double(values.count)
    }

    static func stdDev(_ values: [Double], minCount: Int = 3) -> Double? {
        variance(values, minCount: minCount).map(sqrt)
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
