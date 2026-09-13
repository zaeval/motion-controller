import Foundation
import Testing
@testable import GestureCore

struct PinchTrackerTests {
    @Test func engagesAfterDebounceAndHoldsInsideTheHysteresisBand() {
        var tracker = PinchTracker()
        #expect(tracker.update(pinchRatio: 0.2, sweeping: false) == false)
        #expect(tracker.update(pinchRatio: 0.2, sweeping: false) == true)
        // Between engage (0.35) and release (0.50): stays pinched.
        #expect(tracker.update(pinchRatio: 0.45, sweeping: false) == true)
        #expect(tracker.update(pinchRatio: 0.6, sweeping: false) == true)
        #expect(tracker.update(pinchRatio: 0.6, sweeping: false) == false)
    }

    @Test func singleFrameFlickersAreIgnored() {
        var tracker = PinchTracker()
        #expect(tracker.update(pinchRatio: 0.2, sweeping: false) == false)
        #expect(tracker.update(pinchRatio: 0.9, sweeping: false) == false)
        #expect(tracker.update(pinchRatio: 0.2, sweeping: false) == false)
    }

    @Test func sweepingBlocksEngageButNeverReleases() {
        var tracker = PinchTracker()
        for _ in 0..<5 {
            #expect(tracker.update(pinchRatio: 0.1, sweeping: true) == false)
        }
        _ = tracker.update(pinchRatio: 0.1, sweeping: false)
        #expect(tracker.update(pinchRatio: 0.1, sweeping: false) == true)
        for _ in 0..<5 {
            #expect(tracker.update(pinchRatio: 0.1, sweeping: true) == true)
        }
    }

    @Test func releasingWhileMovingTakesLonger() {
        var tracker = PinchTracker()
        _ = tracker.update(pinchRatio: 0.1, sweeping: false)
        #expect(tracker.update(pinchRatio: 0.1, sweeping: false) == true)
        for _ in 0..<3 {
            #expect(tracker.update(pinchRatio: 0.7, sweeping: false, moving: true) == true)
        }
        #expect(tracker.update(pinchRatio: 0.7, sweeping: false, moving: true) == false)
    }

    @Test func missingJointsHoldState() {
        var tracker = PinchTracker()
        _ = tracker.update(pinchRatio: 0.1, sweeping: false)
        _ = tracker.update(pinchRatio: 0.1, sweeping: false)
        #expect(tracker.update(pinchRatio: nil, sweeping: false) == true)
    }
}
