import Foundation
import Testing
@testable import GestureCore

struct IndexBendDetectorTests {
    private static let frame = 1.0 / 30

    /// Feeds reaches frame by frame (nil drops the frame) and returns the bent state after each.
    private func feed(_ detector: inout IndexBendDetector, _ reaches: [Double?], startingAt t0: TimeInterval = 0) -> [Bool] {
        reaches.enumerated().map { offset, reach in detector.update(reach, at: t0 + Double(offset) * Self.frame) }
    }

    private func repeated(_ reach: Double?, _ count: Int) -> [Double?] {
        Array(repeating: reach, count: count)
    }

    @Test func bendingWellShortOfTheStraightReachEngagesAndStraighteningReleases() {
        var detector = IndexBendDetector()
        let straight = feed(&detector, repeated(0.95, 15))
        #expect(!straight.contains(true))
        #expect(abs((detector.straightReach ?? 0) - 0.95) < 1e-9)
        let bending = feed(&detector, repeated(0.75, 3), startingAt: 0.5)
        #expect(bending == [false, false, true])
        let straightening = feed(&detector, repeated(0.93, 2), startingAt: 0.6)
        #expect(straightening == [true, false])
    }

    @Test func theStraightReachIsWhateverThisHandShowsAndHoldsThroughALongBend() {
        // An index that reaches 0.8 straight is straight for this hand, and 0.75 is no bend of it.
        var short = IndexBendDetector()
        let relaxed = feed(&short, repeated(0.8, 15) + repeated(0.75, 10))
        #expect(!relaxed.contains(true))

        // Ten seconds bent empties the window, but the straight reach doesn't sink and the bend holds.
        var long = IndexBendDetector()
        _ = feed(&long, repeated(0.95, 15))
        let bent = feed(&long, repeated(0.7, 300), startingAt: 0.5)
        #expect(bent.last == true)
        #expect(abs((long.straightReach ?? 0) - 0.95) < 1e-9)
    }

    @Test func aTapInProgressIsNotABend() {
        var detector = IndexBendDetector()
        _ = feed(&detector, repeated(0.95, 15))
        // Four frames dipped deep for a tap, then straight again.
        let tap = (0..<6).map { offset in
            detector.update(offset < 4 ? 0.5 : 0.95, at: 0.5 + Double(offset) * Self.frame, holding: offset < 4)
        }
        #expect(!tap.contains(true))
    }

    @Test func dropoutsAndFoldedFramesHoldTheBendButALostHandStartsOver() {
        var detector = IndexBendDetector()
        _ = feed(&detector, repeated(0.95, 15))
        _ = feed(&detector, repeated(0.7, 3), startingAt: 0.5)
        #expect(detector.isBent)
        let held = feed(&detector, repeated(nil, 15) + repeated(0.1, 5), startingAt: 0.6)
        #expect(held.allSatisfy { $0 })
        let returned = feed(&detector, [0.7], startingAt: 3.0)
        #expect(returned == [false])
        #expect(detector.straightReach == nil)
    }
}
