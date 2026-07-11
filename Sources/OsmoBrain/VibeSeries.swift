import Foundation
import OsmoCore

/// The trend across recent vibe samples: is this relationship warming, steady,
/// or cooling? A least-squares slope over the recent window, silent below a
/// sample floor. Pure and deterministic.
public struct VibeSeries: Equatable, Sendable {
    /// Most recent sample's score.
    public var latest: Double?
    /// Per-day slope over the recent window (positive = warming).
    public var slopePerDay: Double?
    public var sampleCount: Int

    public var isEmpty: Bool { sampleCount < VibeSeries.minSamples }

    static let minSamples = 3
    static let window: TimeInterval = 14 * 86_400
    /// Slope magnitude (per day) beyond which we call it a real trend, not noise.
    static let trendThreshold = 0.03

    public enum Trend: String, Sendable { case warming, steady, cooling, insufficient }

    public var trend: Trend {
        guard !isEmpty, let s = slopePerDay else { return .insufficient }
        if s >= VibeSeries.trendThreshold { return .warming }
        if s <= -VibeSeries.trendThreshold { return .cooling }
        return .steady
    }

    public static func read(_ samples: [VibeSample], now: Date = Date()) -> VibeSeries {
        let cutoff = now.addingTimeInterval(-window)
        let inWindow: (VibeSample) -> Bool = { $0.sampledAt >= cutoff && $0.sampledAt <= now }
        let recent = samples.filter(inWindow).sorted { $0.sampledAt < $1.sampledAt }
        guard recent.count >= minSamples else {
            return VibeSeries(latest: recent.last?.score, slopePerDay: nil, sampleCount: recent.count)
        }

        // Least-squares slope of score vs. days-since-first-sample.
        let t0 = recent.first!.sampledAt
        let xs = recent.map { $0.sampledAt.timeIntervalSince(t0) / 86_400 }
        let ys = recent.map(\.score)
        let n = Double(recent.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<recent.count {
            num += (xs[i] - meanX) * (ys[i] - meanY)
            den += (xs[i] - meanX) * (xs[i] - meanX)
        }
        let slope = den > 0 ? num / den : nil

        return VibeSeries(latest: recent.last?.score, slopePerDay: slope, sampleCount: recent.count)
    }
}
