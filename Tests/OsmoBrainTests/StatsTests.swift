import Testing
import Foundation
@testable import OsmoBrain

@Suite("Stats — nearest-rank percentiles with a sample floor")
struct StatsTests {
    @Test("Below the sample floor everything is nil")
    func floor() {
        #expect(Stats.percentile([1, 2], 0.5) == nil)
        #expect(Stats.median([1, 2]) == nil)
        #expect(Stats.variance([1]) == nil)
    }

    @Test("Median is the middle value")
    func median() {
        #expect(Stats.median([3, 1, 2]) == 2)
        #expect(Stats.median([10, 20, 30, 40, 50]) == 30)
    }

    @Test("p25 <= median <= p75 and all lie within the data range")
    func ordered() {
        let v: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let p25 = Stats.percentile(v, 0.25)!
        let p50 = Stats.percentile(v, 0.50)!
        let p75 = Stats.percentile(v, 0.75)!
        #expect(p25 <= p50)
        #expect(p50 <= p75)
        #expect(p25 >= 1 && p75 <= 10)
    }

    @Test("q clamps to [0,1]; q<=0 is the min, q>=1 is the max")
    func clamp() {
        let v: [Double] = [5, 1, 9, 3, 7]
        #expect(Stats.percentile(v, 0) == 1)
        #expect(Stats.percentile(v, 1) == 9)
        #expect(Stats.percentile(v, -5) == 1)
        #expect(Stats.percentile(v, 5) == 9)
    }

    @Test("Variance is zero for constant data, positive otherwise")
    func variance() {
        #expect(Stats.variance([4, 4, 4, 4]) == 0)
        #expect((Stats.variance([1, 2, 3, 4, 5]) ?? 0) > 0)
    }
}
